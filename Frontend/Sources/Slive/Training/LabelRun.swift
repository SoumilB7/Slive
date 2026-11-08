import AppKit
import AVFoundation
import Combine
import Foundation

/// How Should-be labels are made. Persisted in Settings.
enum GroundTruthRecipe: String {
    /// Slive Custom 4: the 3-way consensus, then gpt-5.5 formats the label
    /// and a code check keeps only allowed edits (backend `label_format`).
    /// The default.
    case consensusFormat
    /// gpt-transcribe + whisper-1 + what Slive typed; the version they agree
    /// on wins. Measured best on Soumil's blind picks (1.4% WER vs 13.5% for
    /// the old gpt-4o-transcribe label model).
    case consensus
    /// One provider/model from the picker (Gemini, gpt-audio, local, Whisper…).
    case single

    /// Labels by the 3-way consensus (with or without the format step).
    var isConsensus: Bool { self != .single }
}

/// One entry in the Data page's ground-truth picker: a consensus recipe,
/// or a single audio-capable provider. Lives here — not in
/// `AssistantProvider` — so the recipe can never leak into Assistant pickers.
enum GroundTruthSource: Hashable, Identifiable {
    case consensusFormat
    case consensus
    case provider(AssistantProvider)

    /// The recipes, in picker order (providers follow a divider).
    static let recipes: [GroundTruthSource] = [.consensusFormat, .consensus]

    var id: String {
        switch self {
        case .consensusFormat: return "consensusFormat"
        case .consensus: return "consensus"
        case .provider(let p): return p.rawValue
        }
    }

    var title: String {
        switch self {
        case .consensusFormat: return "Slive Custom 4 : 3 way check + format"
        case .consensus: return "Slive Custom : 3 way check"
        case .provider(let p): return p.displayName
        }
    }

    /// Providers whose models accept audio input (Anthropic's API doesn't).
    /// Local qualifies via audio-capable downloads (e.g. Gemma 3n); Whisper
    /// is the fully on-device judge. Declared per provider in the catalog
    /// (`.audioTranscribe`).
    static var singleProviders: [AssistantProvider] { ProviderCatalog.groundTruthChoices }
}

/// Which samples a consensus run touches, and which labels deserve a listen.
/// Pure, so the self-test drives it directly.
enum LabelScope {
    /// `llmModel` prefix of every consensus label ("consensus · whisper-1").
    static let consensusTag = "consensus"
    /// Below this the transcribers disagreed enough that a human should listen.
    static let lowAgreement = 0.8

    static func modelTag(chosen: String) -> String {
        chosen.isEmpty ? consensusTag : "\(consensusTag) · \(chosen)"
    }

    static func isConsensus(_ sample: EditSample) -> Bool {
        sample.llmTranscript != nil && (sample.llmModel ?? "").hasPrefix(consensusTag)
    }

    /// In scope: has audio, no human label (those always win), and its model
    /// label is missing or from an older recipe — so a re-click resumes.
    static func needsConsensus(_ sample: EditSample, hasAudio: Bool) -> Bool {
        hasAudio && sample.finalText.isEmpty && !isConsensus(sample)
    }

    static func needsALook(_ sample: EditSample) -> Bool {
        sample.finalText.isEmpty && isConsensus(sample)
            && (sample.llmAgreement ?? 1) < lowAgreement
    }

    /// Slive Custom 4's scope: has audio, no human label, and either no
    /// consensus label or no format step yet. A consensus row only needs
    /// the format call.
    static func needsFormat(_ sample: EditSample, hasAudio: Bool) -> Bool {
        hasAudio && sample.finalText.isEmpty
            && (!isConsensus(sample) || sample.llmFormatStatus == nil)
    }

    /// What `recipe`'s one-click run would do to this sample.
    static func inScope(_ sample: EditSample, recipe: GroundTruthRecipe, hasAudio: Bool) -> Bool {
        recipe == .consensusFormat ? needsFormat(sample, hasAudio: hasAudio)
                                   : needsConsensus(sample, hasAudio: hasAudio)
    }

    /// The format step skips labels the training gate rejects (agreement
    /// < 0.8 or < 4 words) without an API call — mirrors `should_skip` in
    /// Backend/src/flowy/label_format.py. For the estimate only.
    static let minFormatWords = 4

    static func formatWouldSkip(_ sample: EditSample) -> Bool {
        let words = (sample.llmTranscript ?? "").split(whereSeparator: \.isWhitespace).count
        return (sample.llmAgreement.map { $0 < lowAgreement } ?? false) || words < minFormatWords
    }
}

/// Cost and time before you click. Pure.
enum LabelEstimate {
    /// gpt-transcribe ($0.0045/min) + whisper-1 ($0.006/min).
    static let dollarsPerAudioMinute = 0.0045 + 0.006
    /// Slive captures Float32 16 kHz mono: 64,000 bytes per second.
    static let bytesPerSecond = 64_000.0
    static let headerBytes: Int64 = 4_096
    /// Clips in flight at once.
    static let concurrency = 4

    /// One Slive Custom 4 format call: ~1.6k input tokens (the instruction
    /// and five examples) + ~0.2k output at gpt-5.5's $5 / $30 per 1M ≈
    /// $0.013 uncached. Measured Nov 9 2026 on 35 clips: $0.0075 a call,
    /// since ~80% of the input is a cached prefix — this keeps the uncached
    /// price as the upper bound. A row that already has a consensus label
    /// pays only this.
    static let formatDollarsPerCall = 0.015
    /// Wall time of one format call (one short chat reply).
    static let formatSecondsPerCall = 4.0
    /// What one new dictation costs when labeled automatically: the
    /// consensus on a typical clip plus one format call, rounded up.
    static let autoLabelDollarsPerDictation = 0.025

    static func formatDollars(calls: Int) -> Double { Double(calls) * formatDollarsPerCall }

    static func formatSeconds(calls: Int, concurrency: Int = concurrency) -> Double {
        Double(calls) * formatSecondsPerCall / Double(max(1, concurrency))
    }

    /// Seconds of audio in a capture, from its file size alone (a stat, not
    /// a file open — cheap across thousands of clips).
    static func audioSeconds(fileBytes: Int64) -> Double {
        Double(max(0, fileBytes - headerBytes)) / bytesPerSecond
    }

    static func dollars(audioSeconds: Double) -> Double {
        audioSeconds / 60 * dollarsPerAudioMinute
    }

    /// Wall time for one clip: the slower of the two parallel calls, which the
    /// label bench measured at ≈1–3.4 s for 3–42 s clips.
    static func clipSeconds(audioSeconds: Double) -> Double {
        1.5 + 0.04 * audioSeconds
    }

    static func runSeconds(clips: Int, audioSeconds: Double,
                           concurrency: Int = concurrency) -> Double {
        guard clips > 0 else { return 0 }
        return (Double(clips) * 1.5 + 0.04 * audioSeconds) / Double(max(1, concurrency))
    }

    /// Remaining time from observed throughput; nil until enough clips have
    /// finished to trust it (the caller falls back to the static estimate).
    static func eta(processed: Int, total: Int, elapsed: TimeInterval) -> Double? {
        guard processed >= concurrency, elapsed > 0 else { return nil }
        return elapsed / Double(processed) * Double(max(0, total - processed))
    }

    static func dollarsText(_ dollars: Double) -> String {
        dollars < 0.01 ? "<$0.01" : String(format: "~$%.2f", dollars)
    }

    /// Sub-cent precision for one clip's price ("~$0.025").
    static func centsText(_ dollars: Double) -> String {
        String(format: "~$%.3f", dollars)
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "~\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "~\(minutes / 60) h" : "~\(minutes / 60) h \(rest) min"
    }
}

/// The ground-truth engine. Every label — the one-click consensus run, a
/// single-provider Run all / Run left, a row's Get or redo — runs here, not
/// in the Data page, so a run keeps going when you leave the page or close
/// Settings. The page only observes.
@MainActor
final class LabelRun: ObservableObject {
    static let shared = LabelRun()

    /// The one-click to-do list and its price, refreshed as samples change.
    struct Scope: Equatable {
        var ids: [String] = []
        /// Rows that need the consensus (transcription) call, and their audio.
        var transcribeCount = 0
        var audioSeconds: Double = 0
        /// Format calls that will reach the API (Slive Custom 4 only).
        var formatCalls = 0
        var count: Int { ids.count }
        var dollars: Double {
            LabelEstimate.dollars(audioSeconds: audioSeconds) + LabelEstimate.formatDollars(calls: formatCalls)
        }
        var seconds: Double {
            LabelEstimate.runSeconds(clips: transcribeCount, audioSeconds: audioSeconds)
                + LabelEstimate.formatSeconds(calls: formatCalls)
        }
    }

    @Published private(set) var isRunning = false
    /// True while the running (or last) bulk run is the consensus one.
    @Published private(set) var isConsensusRun = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    /// Clips this consensus run couldn't label — "Retry N failed".
    @Published private(set) var failedIDs: [String] = []
    /// Sample ids being labeled right now (row spinners).
    @Published private(set) var inFlight: Set<String> = []
    /// The last error or stop note, shown under the buttons.
    @Published private(set) var message: String?
    /// The message is a key problem — the fix is in Models.
    @Published private(set) var needsKeyFix = false
    /// Mean agreement and low-agreement count for this run's labels.
    @Published private(set) var agreementMean: Double?
    @Published private(set) var lowAgreementCount = 0
    /// Single-provider runs stop on the first error; the untouched tail
    /// lets "Run left" resume exactly there.
    @Published private(set) var remaining: [String] = []
    /// The exact prompt the most recent label was seeded with.
    @Published private(set) var lastPrompt: String?
    @Published private(set) var lastPromptMeta: String?
    @Published private(set) var scope = Scope()
    @Published private(set) var startedAt: Date?
    /// Static estimate for this run, used until throughput is measurable.
    @Published private(set) var estimatedSeconds: Double = 0

    private let store = TrainingStore.shared
    private let settings = Settings.shared
    private let providers = ProviderStore.shared
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var lastFailure: String?
    private var agreementSum = 0.0
    private var agreementCount = 0
    /// Audio sizes never change after capture — one stat per clip, ever.
    private var sizeCache: [String: Int64] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// New dictations waiting for their automatic label (behind any run).
    private var autoQueue: [String] = []

    private init() {
        store.$samples
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshScope() }
            .store(in: &cancellables)
    }

    /// Clips done or failed so far.
    var processed: Int { done + failedIDs.count }

    /// Remaining time: measured once a few clips are back, estimated before.
    func etaSeconds(now: Date = Date()) -> Double {
        guard let startedAt else { return 0 }
        if let eta = LabelEstimate.eta(processed: processed, total: total,
                                       elapsed: now.timeIntervalSince(startedAt)) {
            return eta
        }
        return max(0, estimatedSeconds - now.timeIntervalSince(startedAt))
    }

    // MARK: - Scope

    func refreshScope() {
        let next = makeScope(store.samples, recipe: settings.groundTruthRecipe)
        if next != scope { scope = next }
    }

    /// What `recipe`'s run would do to `samples`, priced.
    private func makeScope(_ samples: [EditSample], recipe: GroundTruthRecipe) -> Scope {
        var s = Scope()
        let formats = recipe == .consensusFormat
        for sample in samples {
            // Cheap field checks first; the audio stat only for candidates.
            guard LabelScope.inScope(sample, recipe: recipe, hasAudio: true),
                  let bytes = audioBytes(sample) else { continue }
            s.ids.append(sample.id)
            let transcribe = !formats || !LabelScope.isConsensus(sample)
            if transcribe {
                s.transcribeCount += 1
                s.audioSeconds += LabelEstimate.audioSeconds(fileBytes: bytes)
            }
            if formats && (transcribe || !LabelScope.formatWouldSkip(sample)) { s.formatCalls += 1 }
        }
        return s
    }

    private func audioBytes(_ sample: EditSample) -> Int64? {
        if let cached = sizeCache[sample.id] { return cached }
        guard let url = store.audioURL(sample) else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        sizeCache[sample.id] = bytes
        return bytes
    }

    // MARK: - Consensus (one click)

    /// Label every in-scope clip. Re-clicking after a stop resumes: rows
    /// already labeled by consensus are out of scope.
    func labelEverything() {
        store.loadSamplesIfNeeded()
        refreshScope()
        runConsensus(ids: scope.ids, estimate: scope.seconds,
                     format: settings.groundTruthRecipe == .consensusFormat)
    }

    func retryFailed() {
        let failed = Set(failedIDs)
        let format = settings.groundTruthRecipe == .consensusFormat
        // Only what's still missing: a row whose consensus landed before its
        // format call failed retries the format call alone.
        let retry = makeScope(store.samples.filter { failed.contains($0.id) },
                              recipe: format ? .consensusFormat : .consensus)
        if retry.ids.isEmpty { failedIDs = [] }
        runConsensus(ids: retry.ids, estimate: retry.seconds, format: format)
    }

    // MARK: - New dictations

    /// Queue a just-captured dictation for Slive Custom 4 (consensus, then
    /// format) when that's the recipe and "Label new dictations
    /// automatically" is on. Runs behind any running label pass, one at a
    /// time; no key = nothing happens; failures count like a bulk run's
    /// (retryable) and never interrupt dictation with an alert.
    func labelNew(id: String) {
        guard autoLabelsNew else { return }
        autoQueue.append(id)
        // Off the dictation's own call stack.
        Task { @MainActor [weak self] in self?.drainAutoQueue() }
    }

    private var autoLabelsNew: Bool {
        settings.autoLabelNew && settings.groundTruthRecipe == .consensusFormat
            && !providers.apiKey(for: ProviderCatalog.consensusKeyProvider).isEmpty
    }

    private func drainAutoQueue() {
        guard !isRunning, !autoQueue.isEmpty else { return }
        guard autoLabelsNew else { autoQueue = []; return }
        // A rewrite needs the whole index in memory, not just new rows.
        store.loadSamplesIfNeeded()
        let queued = Set(autoQueue)
        autoQueue = []
        let todo = makeScope(store.samples.filter { queued.contains($0.id) && !inFlight.contains($0.id) },
                             recipe: .consensusFormat)
        runConsensus(ids: todo.ids, estimate: todo.seconds, format: true, auto: true)
    }

    /// Cancel cleanly: in-flight requests are dropped, finished labels kept.
    func stop() {
        task?.cancel()
    }

    /// The consensus run; with `format`, Slive Custom 4 (consensus where
    /// missing, then the format call). `auto` is a new dictation's label:
    /// it keeps the earlier runs' failures (so they stay retryable) and
    /// never offers problem reports.
    private func runConsensus(ids: [String], estimate: Double, format: Bool, auto: Bool = false) {
        guard !isRunning, !ids.isEmpty else { return }
        let key = providers.apiKey(for: ProviderCatalog.consensusKeyProvider)
        guard !key.isEmpty else {
            if auto { return }
            message = GroundTruthClient.missingOpenAIKeyMessage
            needsKeyFix = true
            return
        }
        begin(total: ids.count, consensus: true, estimate: estimate)
        if !auto { failedIDs = [] }
        lastFailure = nil
        let hotwords = settings.hotwords
        let context = settings.contextPrompt
        let base = settings.consensusPrompt
        let options = JobOptions(key: key, hotwords: hotwords, context: context, base: base,
                                 format: format, quiet: auto)
        task = Task { [weak self] in
            guard let self else { return }
            let completed = await self.consensusLoop(ids: ids, options: options)
            if completed {
                let failed = self.failedIDs.count
                self.message = failed == 0 ? nil
                    : "\(failed) failed: \(self.lastFailure ?? "unknown")"
            }
            self.finish()
        }
    }

    /// What one clip came back with. A consensus label that landed before a
    /// failed (or cancelled) format call is still kept.
    private struct Outcome {
        let id: String
        var consensus: GroundTruthClient.ConsensusResult?
        var format: GroundTruthClient.FormatResult?
        var error: Error?
        var cancelled = false
    }

    private struct Job {
        let id: String
        let url: URL
        let typed: String
        /// The stored consensus label when only the format call is needed.
        let label: String?
        let agreement: Double?
    }

    private struct JobOptions: Sendable {
        let key: String
        let hotwords: String
        let context: String
        let base: String
        let format: Bool
        /// No problem reports (a new dictation's background label).
        let quiet: Bool
    }

    /// A sliding window of `LabelEstimate.concurrency` clips. A failed clip
    /// is counted and the run moves on; only a key problem stops it.
    private func consensusLoop(ids: [String], options: JobOptions) async -> Bool {
        let byID = Dictionary(store.samples.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let jobs: [Job] = ids.compactMap { id in
            guard let sample = byID[id], let url = store.audioURL(sample) else { return nil }
            // Custom 4 reuses a consensus label: no transcription, no upload.
            let reuse = options.format && LabelScope.isConsensus(sample)
            return Job(id: id, url: url, typed: sample.transcript,
                       label: reuse ? sample.llmTranscript : nil,
                       agreement: reuse ? sample.llmAgreement : nil)
        }
        total = jobs.count   // rows deleted since the click drop out
        var cursor = 0
        return await withTaskGroup(of: Outcome.self, returning: Bool.self) { group in
            while cursor < min(LabelEstimate.concurrency, jobs.count) {
                let job = jobs[cursor]
                cursor += 1
                inFlight.insert(job.id)
                group.addTask { await Self.consensusJob(job, options) }
            }
            while let outcome = await group.next() {
                inFlight.remove(outcome.id)
                // Consensus first: a new label clears the old format fields.
                if let result = outcome.consensus {
                    applyConsensus(id: outcome.id, result, hotwords: options.hotwords, coalesced: true)
                }
                if let result = outcome.format {
                    store.setFormat(id: outcome.id, formatted: result.formatted, status: result.status,
                                    model: result.model, coalesced: true)
                    TranscriptDiffCache.remove(id: outcome.id)
                }
                if let error = outcome.error {
                    if let stop = error as? SliveError, stop.stopsRun {
                        // A key problem or a dead backend fails every clip
                        // the same way — stop now, say why.
                        message = stop.localizedDescription
                        if case .serverDown = stop { needsKeyFix = false } else { needsKeyFix = true }
                        group.cancelAll()
                        return false
                    }
                    if !failedIDs.contains(outcome.id) { failedIDs.append(outcome.id) }
                    lastFailure = error.localizedDescription
                    message = "Last failure: \(error.localizedDescription)"
                } else if !outcome.cancelled {
                    failedIDs.removeAll { $0 == outcome.id }
                    done += 1
                }
                if Task.isCancelled {
                    message = "Stopped · \(done.formatted()) labeled"
                    group.cancelAll()
                    return false
                }
                if cursor < jobs.count {
                    let job = jobs[cursor]
                    cursor += 1
                    inFlight.insert(job.id)
                    group.addTask { await Self.consensusJob(job, options) }
                }
            }
            return true
        }
    }

    /// One clip, off the main actor: validate the audio, ask the backend
    /// for the consensus (unless the job reuses one), then the format step.
    private nonisolated static func consensusJob(_ job: Job, _ options: JobOptions) async -> Outcome {
        var outcome = Outcome(id: job.id)
        do {
            var label = job.label
            var agreement = job.agreement
            if label == nil {
                _ = try validatedAudioSeconds(job.url)
                let result = try await GroundTruthClient().consensus(
                    audioURL: job.url, apiKey: options.key, typed: job.typed,
                    hotwords: options.hotwords, context: options.context, base: options.base,
                    quiet: options.quiet)
                outcome.consensus = result
                label = labelText(result, hotwords: options.hotwords)
                agreement = result.agreement
            }
            if options.format, let label {
                try Task.checkCancellation()
                outcome.format = try await GroundTruthClient().format(
                    label: label, apiKey: options.key, hotwords: options.hotwords,
                    agreement: agreement, quiet: options.quiet)
            }
        } catch is CancellationError {
            outcome.cancelled = true
        } catch let error as URLError where error.code == .cancelled {
            outcome.cancelled = true
        } catch {
            outcome.error = error
        }
        return outcome
    }

    /// The stored label: the dictation pipeline's corrections only (an LLM
    /// transcript has no decoder artifacts to clean). The format step reads
    /// exactly this text.
    private nonisolated static func labelText(_ result: GroundTruthClient.ConsensusResult,
                                              hotwords: String) -> String {
        DictationPipeline.standard(vocabulary: hotwords).correct(result.text)
    }

    /// Spelling pass + store. Human labels (`finalText`) are never touched —
    /// training already prefers them.
    private func applyConsensus(id: String, _ result: GroundTruthClient.ConsensusResult,
                                hotwords: String, coalesced: Bool) {
        store.setLLMTranscript(id: id, text: Self.labelText(result, hotwords: hotwords),
                               model: LabelScope.modelTag(chosen: result.chosen),
                               agreement: result.agreement, coalesced: coalesced)
        TranscriptDiffCache.remove(id: id)
        agreementSum += result.agreement
        agreementCount += 1
        agreementMean = agreementSum / Double(agreementCount)
        if result.agreement < LabelScope.lowAgreement { lowAgreementCount += 1 }
        lastPrompt = result.prompt
        lastPromptMeta = "Slive Custom · \(result.chosen)"
    }

    // MARK: - Single provider (the picker's other recipes)

    /// Bulk-label with one provider: missing only, or every recording.
    func runSingle(includeExisting: Bool) {
        store.loadSamplesIfNeeded()
        let todo = store.samples.filter {
            store.audioURL($0) != nil && (includeExisting || $0.llmTranscript == nil)
        }
        runSingle(ids: todo.map(\.id))
    }

    /// Resume a stopped single-provider run: only what it never reached.
    func runRemaining() {
        runSingle(ids: leftoverIDs)
    }

    /// Ids a stopped run left behind that still exist and have audio.
    var leftoverIDs: [String] {
        let present = Set(store.samples.filter { store.audioURL($0) != nil }.map(\.id))
        return remaining.filter(present.contains)
    }

    /// Sequential on purpose: provider rate limits, and one error stops the
    /// run instead of failing 30 requests at once — remembering the
    /// untouched tail so "Run left" can pick it up.
    private func runSingle(ids: [String]) {
        guard !isRunning, !ids.isEmpty else { return }
        let provider = settings.groundTruthProvider
        let model = settings.groundTruthModel
        begin(total: ids.count, consensus: false, estimate: 0)
        remaining = []
        task = Task { [weak self] in
            guard let self else { return }
            for (index, id) in ids.enumerated() {
                if Task.isCancelled {
                    self.remaining = Array(ids[index...])
                    self.message = "Stopped — \(self.remaining.count) left"
                    break
                }
                guard let sample = self.store.samples.first(where: { $0.id == id }),
                      let url = self.store.audioURL(sample) else { continue }
                self.inFlight.insert(id)
                do {
                    let text = try await self.singleText(url: url, provider: provider, model: model)
                    self.inFlight.remove(id)
                    self.store.setLLMTranscript(id: id, text: text, model: model, coalesced: true)
                    TranscriptDiffCache.remove(id: id)
                    self.done += 1
                } catch {
                    self.inFlight.remove(id)
                    self.remaining = Array(ids[index...])
                    self.message = Task.isCancelled
                        ? "Stopped — \(self.remaining.count) left"
                        : "\(error.localizedDescription) — stopped, \(self.remaining.count) left"
                    break
                }
            }
            self.finish()
        }
    }

    // MARK: - One row (Get / redo)

    /// Label one sample with the selected recipe, right away.
    func labelOne(_ sample: EditSample) {
        guard let url = store.audioURL(sample), !inFlight.contains(sample.id) else { return }
        inFlight.insert(sample.id)
        message = nil
        needsKeyFix = false
        let recipe = settings.groundTruthRecipe
        let provider = settings.groundTruthProvider
        let model = settings.groundTruthModel
        let hotwords = settings.hotwords
        let context = settings.contextPrompt
        let base = settings.consensusPrompt
        let key = providers.apiKey(for: ProviderCatalog.consensusKeyProvider)
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(sample.id) }
            do {
                if recipe.isConsensus {
                    // A row's redo is a full one: fresh consensus, then (Custom 4) the format step.
                    let job = Job(id: sample.id, url: url, typed: sample.transcript, label: nil, agreement: nil)
                    let outcome = await Self.consensusJob(job, JobOptions(
                        key: key, hotwords: hotwords, context: context, base: base,
                        format: recipe == .consensusFormat, quiet: false))
                    if let result = outcome.consensus {
                        self.applyConsensus(id: sample.id, result, hotwords: hotwords, coalesced: false)
                    }
                    if let result = outcome.format {
                        self.store.setFormat(id: sample.id, formatted: result.formatted,
                                             status: result.status, model: result.model)
                    }
                    if let error = outcome.error { throw error }
                } else {
                    let text = try await self.singleText(url: url, provider: provider, model: model)
                    self.store.setLLMTranscript(id: sample.id, text: text, model: model)
                    TranscriptDiffCache.remove(id: sample.id)
                }
            } catch {
                self.message = error.localizedDescription
                if case .missingKey? = error as? SliveError { self.needsKeyFix = true }
            }
        }
    }

    // MARK: - Shared

    private func begin(total: Int, consensus: Bool, estimate: Double) {
        isRunning = true
        isConsensusRun = consensus
        self.total = total
        done = 0
        message = nil
        needsKeyFix = false
        agreementSum = 0
        agreementCount = 0
        agreementMean = nil
        lowAgreementCount = 0
        startedAt = Date()
        estimatedSeconds = estimate
        // Keep the Mac awake for a long run; idle sleep would stall it.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Labeling ground truth")
    }

    private func finish() {
        store.flushPendingWrites()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        inFlight.removeAll()
        isRunning = false
        startedAt = nil
        task = nil
        refreshScope()
        drainAutoQueue()   // new dictations that waited behind this run
    }

    /// One single-provider transcription: Whisper runs in-app on the
    /// WhisperKit registry (no backend, no key); everything else goes through
    /// the backend proxy with the user's Vocabulary and prompt.
    private func singleText(url: URL, provider: AssistantProvider, model: String) async throws -> String {
        _ = try Self.validatedAudioSeconds(url)
        if provider == .whisper {
            lastPrompt = "(Whisper takes no prompt.)"
            lastPromptMeta = "Whisper · \(model)"
            guard let text = await TranscriptionModel.shared.transcribe(url, model: model),
                  !text.isEmpty else {
                throw SliveError.local(
                    "Whisper not ready, or clip silent.")
            }
            return text
        }
        let override = settings.groundTruthPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await GroundTruthClient().transcribe(
            audioURL: url, provider: provider, model: model,
            apiKey: providers.apiKey(for: provider),
            baseURL: providers.baseURL(for: provider),
            vocabHint: GroundTruthClient.vocabHint(
                hotwords: settings.hotwords, context: settings.contextPrompt),
            promptOverride: override.isEmpty ? nil : override)
        lastPrompt = result.prompt
        lastPromptMeta = "\(provider.displayName) · \(model)"
        return result.text
    }

    /// Proof the audio is real BEFORE anything is sent: open the file as
    /// audio and count its frames. An empty or truncated WAV produces exactly
    /// the "model says there is no audio" failure — so it fails here, loudly.
    nonisolated static func validatedAudioSeconds(_ url: URL) throws -> Double {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw SliveError.local(
                "Audio file is broken.")
        }
        let seconds = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        guard seconds >= 0.3 else {
            throw SliveError.local(String(
                format: "Too short (%.2f s).",
                seconds))
        }
        return seconds
    }
}
