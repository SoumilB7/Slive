import AppKit
import Foundation

/// One captured training data point: the dictation's audio plus what Slive
/// transcribed it as. (`finalText`/`edited`/`confidence` remain in the schema
/// for the later "what it should have been" comparison — today they're stored
/// empty: reading the corrected text back out of the target field needs the AX
/// reads we removed from the typing path.)
struct EditSample: Codable, Identifiable {
    let id: String
    let createdAt: Date
    /// Bundle id of the app the field belonged to (context only).
    let app: String?
    /// What Slive typed in (the model's output for this section).
    let transcript: String
    /// What that section read as when the field lost focus.
    let finalText: String
    /// Whether the user changed it (`finalText != transcript`).
    let edited: Bool
    /// How sure we are the partition is correct:
    ///  - `high`   — both context anchors matched; the section is precise.
    ///  - `low`    — field was empty around the insertion (no anchors), so the
    ///               whole final value is treated as the section.
    ///  - `unresolved` — anchors couldn't be found (field edited beyond the
    ///               section, or value unreadable); `finalText` may be empty.
    let confidence: String
    /// Relative path (within the store) of the captured audio, if any.
    let audioFile: String?
    /// Ground-truth transcription from an audio-capable LLM (the "should be"
    /// column), and which model produced it. nil until fetched.
    var llmTranscript: String?
    var llmModel: String?
}

/// Local, append-only store for captured edit samples + their audio. Everything
/// stays on disk under Application Support; nothing is uploaded. Off unless the
/// user enables "Capture dictation edits" in Settings.
@MainActor
final class TrainingStore: ObservableObject {
    static let shared = TrainingStore()

    /// All captured samples, oldest → newest (the UI shows them reversed).
    @Published private(set) var samples: [EditSample] = []
    /// The most recent sample, so the UI can show the latest comparison.
    @Published private(set) var latest: EditSample?
    /// Total bytes used on disk (audio + index).
    @Published private(set) var totalBytes: Int64 = 0

    /// Number of samples captured so far.
    var count: Int { samples.count }

    /// The configured cap in bytes.
    var maxBytes: Int64 { Int64(max(0, Settings.shared.captureMaxGB) * 1_073_741_824) }
    /// True once usage has reached the cap — capture pauses here.
    var isOverLimit: Bool { totalBytes >= maxBytes }
    /// 0…1 fraction of the cap in use (for the usage bar).
    var usageFraction: Double {
        guard maxBytes > 0 else { return 0 }
        return min(1, Double(totalBytes) / Double(maxBytes))
    }

    private let root: URL
    private let audioDir: URL
    private let indexFile: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("Slive/training", isDirectory: true)
        audioDir = root.appendingPathComponent("audio", isDirectory: true)
        indexFile = root.appendingPathComponent("samples.jsonl", isDirectory: false)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        samples = loadSamples()
        latest = samples.last
        totalBytes = computeSize()
    }

    /// Absolute URL of a sample's audio, if present on disk.
    func audioURL(_ sample: EditSample) -> URL? {
        guard let rel = sample.audioFile else { return nil }
        let url = root.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete every captured sample + audio and reset usage.
    func clearAll() {
        try? FileManager.default.removeItem(at: indexFile)
        if let files = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        samples = []
        latest = nil
        totalBytes = 0
        Log.training("cleared all samples")
    }

    /// Copy a source audio file into the store, returning the stored file's
    /// relative path (or nil on failure). Called at capture-start because the
    /// caller's temp wav is deleted moments later.
    func ingestAudio(_ source: URL, id: String) -> String? {
        let dest = audioDir.appendingPathComponent("\(id).wav")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            totalBytes += fileSize(dest)
            return "audio/\(id).wav"
        } catch {
            Log.training("ingestAudio failed: \(error)")
            return nil
        }
    }

    /// Save one dictation as-is: its audio + Slive's transcription. No field
    /// tracking, no final-text comparison — `finalText` stays empty ("audio"
    /// confidence) until a non-AX way to read back edits exists.
    func addRecording(transcript: String, audioURL: URL) {
        let id = UUID().uuidString
        let audioFile = ingestAudio(audioURL, id: id)
        add(EditSample(
            id: id, createdAt: Date(),
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            transcript: transcript, finalText: "",
            edited: false, confidence: "audio", audioFile: audioFile,
            llmTranscript: nil, llmModel: nil))
    }

    /// Attach a ground-truth transcription to a stored sample and persist.
    /// Rewrites the JSONL index (samples are small; simplicity over cleverness).
    func setLLMTranscript(id: String, text: String, model: String) {
        guard let idx = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[idx].llmTranscript = text
        samples[idx].llmModel = model
        if samples[idx].id == latest?.id { latest = samples[idx] }
        rewriteIndex()
    }

    /// Rewrite the whole JSONL index from `samples` (used after in-place edits).
    private func rewriteIndex() {
        var blob = Data()
        for sample in samples {
            guard let line = try? JSONEncoder.iso.encode(sample) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        let oldSize = fileSize(indexFile)
        do {
            try blob.write(to: indexFile, options: .atomic)
            totalBytes += Int64(blob.count) - oldSize
        } catch {
            Log.training("index rewrite failed: \(error)")
        }
    }

    /// Append a finished sample to the index.
    func add(_ sample: EditSample) {
        do {
            let data = try JSONEncoder.iso.encode(sample)
            var line = data
            line.append(0x0A)   // newline-delimited JSON
            appendToIndex(line)
            totalBytes += Int64(line.count)
            samples.append(sample)
            latest = sample
            Log.training("stored sample #\(samples.count) (\(sample.confidence), edited=\(sample.edited))")
        } catch {
            Log.training("encode/store failed: \(error)")
        }
    }

    /// Where the data lives, for a "Reveal in Finder" affordance later.
    var directory: URL { root }

    // MARK: - Internals

    private func appendToIndex(_ line: Data) {
        if let handle = try? FileHandle(forWritingTo: indexFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: indexFile)   // file didn't exist yet
        }
    }

    private func loadSamples() -> [EditSample] {
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(EditSample.self, from: data)
        }
    }

    /// Total size of the index + all audio on disk.
    private func computeSize() -> Int64 {
        var total: Int64 = fileSize(indexFile)
        if let files = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for f in files { total += fileSize(f) }
        }
        return total
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
