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
    /// Human-approved "Should be" text. Empty until edited in the Data page
    /// (legacy rows may contain the old field-readback value).
    var finalText: String
    /// Whether the user changed it (`finalText != transcript`).
    var edited: Bool
    /// How sure we are the partition is correct:
    ///  - `high`   — both context anchors matched; the section is precise.
    ///  - `low`    — field was empty around the insertion (no anchors), so the
    ///               whole final value is treated as the section.
    ///  - `unresolved` — anchors couldn't be found (field edited beyond the
    ///               section, or value unreadable); `finalText` may be empty.
    var confidence: String
    /// Relative path (within the store) of the captured audio, if any.
    let audioFile: String?
    /// Ground-truth transcription from an audio-capable LLM (the "should be"
    /// column), and which model produced it. nil until fetched.
    var llmTranscript: String?
    var llmModel: String?
    /// For consensus labels: how closely the transcribers agreed (0…1). Low
    /// values mark the rows worth a listen. nil for every other label —
    /// and omitted from the JSON line then, so older rows are unchanged.
    var llmAgreement: Double?
    /// For consensus labels: words only the label's transcriber heard —
    /// two or more mark the row for a listen and keep it out of training.
    /// nil (omitted) for every other label and for rows labeled before Nov 9.
    var llmUnconfirmed: [String]?
    /// Slive Custom 4's format step: the formatted label (the plain one
    /// when it wasn't kept), its status (`formatted` | `unchanged` |
    /// `rejected:<reason>` | `skipped`) and model. nil = not formatted yet,
    /// and omitted from the JSON line like `llmAgreement`.
    var llmFormatted: String?
    var llmFormatStatus: String?
    var llmFormatModel: String?

    /// The formatted text to show and train on, when the formatter's output
    /// was kept (`formatted` or `unchanged`).
    var keptFormat: String? {
        guard let llmFormatted, ["formatted", "unchanged"].contains(llmFormatStatus) else { return nil }
        return llmFormatted
    }
}

/// Local, append-only store for captured edit samples + their audio. Everything
/// stays on disk under Application Support; nothing is uploaded. Off unless the
/// user enables "Capture dictation edits" in Settings.
@MainActor
final class TrainingStore: ObservableObject {
    static let shared = TrainingStore()

    /// All captured samples, oldest → newest (the UI shows them reversed).
    @Published private(set) var samples: [EditSample] = [] {
        didSet { revision += 1 }
    }
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
    /// The append-only sample index (`samples.jsonl`).
    private let index: JSONLFileStore<EditSample>

    private init() {
        root = AppSupport.trainingDirectory
        audioDir = root.appendingPathComponent("audio", isDirectory: true)
        indexFile = root.appendingPathComponent("samples.jsonl", isDirectory: false)
        index = JSONLFileStore(url: indexFile, label: "training index")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // totalBytes stays EAGER: the capture write path checks isOverLimit
        // before the Training UI ever opens, and a lazily-zero totalBytes would
        // let capture write past the user's cap. The full samples[] parse (the
        // browser's data) is deferred until the Training tab appears.
        totalBytes = computeSize()
    }

    /// Parse the sample index on demand — the browser/backfill UI is the only
    /// consumer of the full array. Safe against pre-load appends: `add` writes
    /// the file first, so re-reading it here can't drop or duplicate a sample.
    func loadSamplesIfNeeded() {
        guard !samplesLoaded else { return }
        samplesLoaded = true
        // Unreadable lines are copied aside once before any rewrite drops them.
        samples = index.load()
        if latest == nil { latest = samples.last }
    }
    private var samplesLoaded = false

    /// Absolute URL of a sample's audio, if present on disk.
    func audioURL(_ sample: EditSample) -> URL? {
        guard let rel = sample.audioFile else { return nil }
        let url = root.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Render-time views (memoized)

    /// Bumped on every change to `samples` (and on an audio re-check) — the
    /// key the memos below are valid for.
    private var revision = 0
    /// Whether each sample's audio is on disk, by id. The Data page asks for
    /// every sample on every render (counts, row buttons) and re-renders at
    /// 10 Hz during playback; a stat per sample per redraw adds up on main.
    private var audioPresence: [String: Bool] = [:]
    private var summaryMemo: (revision: Int, value: DataSummary)?

    /// `audioURL`'s presence answer, from the memo. Rendering only — label
    /// runs keep the live check right before they read the file.
    func hasAudio(_ sample: EditSample) -> Bool {
        if let known = audioPresence[sample.id] { return known }
        let present = audioURL(sample) != nil
        audioPresence[sample.id] = present
        return present
    }

    /// The memoized URL for a row's play button (nil when there's no audio).
    func cachedAudioURL(_ sample: EditSample) -> URL? {
        guard hasAudio(sample), let rel = sample.audioFile else { return nil }
        return root.appendingPathComponent(rel)
    }

    /// Forget what's known about audio on disk — the Data page calls this on
    /// appear, so a clip deleted in Finder doesn't linger as playable.
    func recheckAudio() {
        guard !audioPresence.isEmpty else { return }   // nothing known yet
        objectWillChange.send()
        audioPresence.removeAll()
        revision += 1
    }

    /// The Data page's counts and jump lists, computed once per change to
    /// `samples` instead of once per render.
    var summary: DataSummary {
        if let memo = summaryMemo, memo.revision == revision { return memo.value }
        let value = Self.summarize(samples, hasAudio: hasAudio, isWayOff: Self.isWayOff)
        summaryMemo = (revision, value)
        return value
    }

    struct DataSummary: Equatable {
        /// Samples with audio on disk.
        var audioCount = 0
        /// Samples with audio but no model label yet.
        var missingCount = 0
        /// Way-off rows, newest first (table order).
        var wayOffIDs: [String] = []
        /// Consensus labels worth a listen, newest first.
        var lookIDs: [String] = []
        /// Look rows, then way-off rows not already among them — the "to check" jump.
        var checkIDs: [String] = []
    }

    /// Pure, so the self-test drives it with stand-in predicates.
    static func summarize(_ samples: [EditSample], hasAudio: (EditSample) -> Bool,
                          isWayOff: (EditSample) -> Bool) -> DataSummary {
        var s = DataSummary()
        for sample in samples.reversed() {
            if hasAudio(sample) {
                s.audioCount += 1
                if sample.llmTranscript == nil { s.missingCount += 1 }
            }
            if isWayOff(sample) { s.wayOffIDs.append(sample.id) }
            if LabelScope.needsALook(sample) { s.lookIDs.append(sample.id) }
        }
        let looks = Set(s.lookIDs)
        s.checkIDs = s.lookIDs + s.wayOffIDs.filter { !looks.contains($0) }
        return s
    }

    /// The label that counts: a human edit wins over the model's.
    static func effectiveTruth(_ sample: EditSample) -> String? {
        if !sample.finalText.isEmpty { return sample.finalText }
        return sample.llmTranscript
    }

    /// Whether this sample's ground truth disagrees with the output by more
    /// than half — usually not a correction but a model gone wrong (answered
    /// the audio, never received it, wrong row). Worth a human look.
    static func isWayOff(_ sample: EditSample) -> Bool {
        guard let truth = effectiveTruth(sample) else { return false }
        return TranscriptDiffCache.divergence(
            id: sample.id, output: sample.transcript, truth: truth) > 0.5
    }

    /// Delete a single sample — its audio file and index entry — and reclaim
    /// the bytes. No-op if it's already gone.
    func remove(id: String) {
        guard let idx = samples.firstIndex(where: { $0.id == id }) else { return }
        let sample = samples[idx]
        if let url = audioURL(sample) {
            totalBytes -= fileSize(url)
            try? FileManager.default.removeItem(at: url)
        }
        audioPresence.removeValue(forKey: id)
        samples.remove(at: idx)
        if latest?.id == id { latest = samples.last }
        rewriteIndex()   // adjusts totalBytes by the index-size delta
        Log.training("removed sample \(id)")
    }

    /// Delete every captured sample + audio and reset usage — including any
    /// index copies set aside as unreadable (they hold transcripts too).
    func clearAll() {
        indexWrites.cancel()   // nothing left to flush
        index.removeAll()      // the index and every set-aside copy of it
        if let files = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        audioPresence.removeAll()
        samples = []
        latest = nil
        totalBytes = 0
        samplesLoaded = true   // the (now-empty) file is fully reflected
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
    /// Returns the stored sample's id (nil when the append failed).
    @discardableResult
    func addRecording(transcript: String, audioURL: URL) -> String? {
        let id = UUID().uuidString
        let audioFile = ingestAudio(audioURL, id: id)
        add(EditSample(
            id: id, createdAt: Date(),
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            transcript: transcript, finalText: "",
            edited: false, confidence: "audio", audioFile: audioFile,
            llmTranscript: nil, llmModel: nil))
        return samples.last?.id == id ? id : nil
    }

    /// Attach a ground-truth transcription to a stored sample and persist.
    /// Rewrites the JSONL index (samples are small; simplicity over cleverness).
    /// `coalesced` is for bulk runs: thousands of labels would otherwise each
    /// rewrite the whole index, so the write folds into one flush at most
    /// `IndexWriteCoalescer.interval` later (and at the run's end).
    func setLLMTranscript(id: String, text: String, model: String,
                          agreement: Double? = nil, unconfirmed: [String]? = nil,
                          coalesced: Bool = false) {
        guard let idx = samples.firstIndex(where: { $0.id == id }) else { return }
        // A new label makes its old formatting stale.
        if samples[idx].llmTranscript != text {
            samples[idx].llmFormatted = nil
            samples[idx].llmFormatStatus = nil
            samples[idx].llmFormatModel = nil
        }
        samples[idx].llmTranscript = text
        samples[idx].llmModel = model
        samples[idx].llmAgreement = agreement
        samples[idx].llmUnconfirmed = unconfirmed
        if samples[idx].id == latest?.id { latest = samples[idx] }
        if coalesced { indexWrites.markDirty() } else { rewriteIndex() }
    }

    /// Store Slive Custom 4's format step for a labeled sample.
    func setFormat(id: String, formatted: String, status: String, model: String,
                   coalesced: Bool = false) {
        guard let idx = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[idx].llmFormatted = formatted
        samples[idx].llmFormatStatus = status
        samples[idx].llmFormatModel = model
        if samples[idx].id == latest?.id { latest = samples[idx] }
        if coalesced { indexWrites.markDirty() } else { rewriteIndex() }
    }

    /// Write any coalesced label changes now (end of a run, app quit).
    func flushPendingWrites() {
        indexWrites.flushNow()
    }

    /// Folds bursts of label writes into one index rewrite. Safe against
    /// dictations captured meanwhile: `add` appends to both the file and
    /// `samples`, and the flush writes all of `samples` — the same JSONL.
    private lazy var indexWrites = IndexWriteCoalescer { [weak self] in self?.rewriteIndex() }

    /// Save an explicit human correction from the Data page. `finalText` is
    /// intentionally separate from `llmTranscript`: the backend's
    /// BEST_AVAILABLE policy already prefers it, while the original model label
    /// remains available for audit and re-running.
    func setManualTranscript(id: String, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let idx = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[idx].finalText = cleaned
        samples[idx].edited = true
        samples[idx].confidence = "manual"
        if samples[idx].id == latest?.id { latest = samples[idx] }
        rewriteIndex()
    }

    /// Rewrite the whole JSONL index from `samples` (used after in-place edits).
    /// Also satisfies any pending coalesced write — it carries every change.
    private func rewriteIndex() {
        indexWrites.cancel()
        let oldSize = fileSize(indexFile)
        do {
            totalBytes += try index.rewrite(samples) - oldSize
        } catch {
            Log.training("index rewrite failed: \(error)")
        }
    }

    /// Append a finished sample to the index. Memory and usage follow the
    /// file: a failed append leaves both untouched, so the browser never
    /// shows a sample the next launch won't find.
    func add(_ sample: EditSample) {
        do {
            // Append-only, with the torn-line guard (see JSONLFileStore).
            totalBytes += try index.append(sample)
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

    // The index format itself — append with the torn-line guard, byte-wise
    // parse, copy-aside-once — lives in `JSONLFileStore`; these stay as the
    // names the self-test pins.

    /// True when the index's last byte closes a line (or there is none).
    nonisolated static func endsLine(_ lastByte: Data?) -> Bool {
        JSONLFileStore<EditSample>.endsLine(lastByte)
    }

    /// Decode a JSONL index byte-wise (a bad byte costs one line, not the
    /// whole file), counting the non-blank lines that didn't decode.
    nonisolated static func parseIndex(_ data: Data) -> (samples: [EditSample], undecodable: Int) {
        let parsed = JSONLFileStore<EditSample>.parse(data)
        return (parsed.elements, parsed.undecodable)
    }

    /// Where an index with unreadable lines is copied before any rewrite.
    nonisolated static func corruptBackupURL(for url: URL, at date: Date) -> URL {
        CorruptBackup.url(for: url, at: date)
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

/// Debounces "the index changed" into at most one write per `interval`: the
/// first mark schedules a flush, later marks ride along until it runs.
/// `flushNow` writes immediately (only if something is pending); `cancel`
/// drops the pending flush once a full rewrite already covered it.
@MainActor
final class IndexWriteCoalescer {
    nonisolated static let interval: TimeInterval = 2
    private let write: () -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private(set) var isPending = false
    /// Bumped by flush/cancel so a timer scheduled for an older batch is a no-op.
    private var generation = 0

    /// `schedule` is injectable so the self-test can fire timers by hand.
    init(schedule: ((@escaping @MainActor () -> Void) -> Void)? = nil,
         write: @escaping () -> Void) {
        self.write = write
        self.schedule = schedule ?? { fire in
            DispatchQueue.main.asyncAfter(deadline: .now() + IndexWriteCoalescer.interval) {
                MainActor.assumeIsolated { fire() }
            }
        }
    }

    func markDirty() {
        guard !isPending else { return }
        isPending = true
        let batch = generation
        schedule { [weak self] in
            guard let self, self.generation == batch else { return }
            self.flushNow()
        }
    }

    func flushNow() {
        guard isPending else { return }
        isPending = false
        generation += 1
        write()
    }

    func cancel() {
        guard isPending else { return }
        isPending = false
        generation += 1
    }
}
