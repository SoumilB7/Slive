import Foundation

/// One captured training data point: what Slive transcribed into a field, and
/// what that same section became by the time the field lost focus. The pair
/// (transcript → finalText) is the supervision signal — where they differ, the
/// user corrected the model.
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
}

/// Local, append-only store for captured edit samples + their audio. Everything
/// stays on disk under Application Support; nothing is uploaded. Off unless the
/// user enables "Capture dictation edits" in Settings.
@MainActor
final class TrainingStore: ObservableObject {
    static let shared = TrainingStore()

    /// Number of samples captured so far (for the Settings readout).
    @Published private(set) var count: Int = 0
    /// The most recent sample, so the UI can show the latest comparison.
    @Published private(set) var latest: EditSample?

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
        count = existingCount()
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
            return "audio/\(id).wav"
        } catch {
            Log.training("ingestAudio failed: \(error)")
            return nil
        }
    }

    /// Append a finished sample to the index.
    func add(_ sample: EditSample) {
        do {
            let data = try JSONEncoder.iso.encode(sample)
            var line = data
            line.append(0x0A)   // newline-delimited JSON
            appendToIndex(line)
            count += 1
            latest = sample
            Log.training("stored sample #\(count) (\(sample.confidence), edited=\(sample.edited))")
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

    private func existingCount() -> Int {
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
