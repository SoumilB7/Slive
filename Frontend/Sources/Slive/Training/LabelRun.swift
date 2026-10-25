import AppKit
import AVFoundation
import Combine
import Foundation

/// How Should-be labels are made. Persisted in Settings.
enum GroundTruthRecipe: String {
    /// gpt-transcribe + whisper-1 + what Slive typed; the version they agree
    /// on wins. Measured best on Soumil's blind picks (1.4% WER vs 13.5% for
    /// the old gpt-4o-transcribe label model).
    case consensus
    /// One provider/model from the picker (Gemini, gpt-audio, local, Whisper…).
    case single
}

/// One entry in the Data page's ground-truth picker: the consensus recipe,
/// or a single audio-capable provider. Lives here — not in
/// `AssistantProvider` — so the recipe can never leak into Assistant pickers.
enum GroundTruthSource: Hashable, Identifiable {
    case consensus
    case provider(AssistantProvider)

    var id: String {
        switch self {
        case .consensus: return "consensus"
        case .provider(let p): return p.rawValue
        }
    }

    var title: String {
        switch self {
        case .consensus: return "Best — 3-way consensus"
        case .provider(let p): return p.displayName
        }
    }

    /// Providers whose models accept audio input (Anthropic's API doesn't).
    /// Local qualifies via audio-capable downloads (e.g. Gemma 3n); Whisper
    /// is the fully on-device judge.
    static let singleProviders: [AssistantProvider] = [.gemini, .openai, .openaiCompatible, .local, .whisper]
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

    /// The consensus to-do list and its price, refreshed as samples change.
    struct Scope: Equatable {
        var ids: [String] = []
        var audioSeconds: Double = 0
        var count: Int { ids.count }
        var dollars: Double { LabelEstimate.dollars(audioSeconds: audioSeconds) }
        var seconds: Double { LabelEstimate.runSeconds(clips: count, audioSeconds: audioSeconds) }
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
        var ids: [String] = []
        var seconds = 0.0
        for sample in store.samples {
            // Cheap field checks first; the audio stat only for candidates.
            guard LabelScope.needsConsensus(sample, hasAudio: true),
                  let bytes = audioBytes(sample) else { continue }
            ids.append(sample.id)
            seconds += LabelEstimate.audioSeconds(fileBytes: bytes)
        }
        let next = Scope(ids: ids, audioSeconds: seconds)
        if next != scope { scope = next }
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
        runConsensus(ids: scope.ids, estimate: scope.seconds)
    }

    func retryFailed() {
        let present = Set(store.samples.map(\.id))
        let ids = failedIDs.filter(present.contains)
        let seconds = ids.compactMap { id in store.samples.first { $0.id == id } }
            .compactMap(audioBytes).map(LabelEstimate.audioSeconds).reduce(0, +)
        runConsensus(ids: ids, estimate: LabelEstimate.runSeconds(clips: ids.count, audioSeconds: seconds))
    }

    /// Cancel cleanly: in-flight requests are dropped, finished labels kept.
    func stop() {
        task?.cancel()
    }

    private func runConsensus(ids: [String], estimate: Double) {
        guard !isRunning, !ids.isEmpty else { return }
        let key = providers.apiKey(for: .openai)
        guard !key.isEmpty else {
            message = GroundTruthClient.missingOpenAIKeyMessage
            needsKeyFix = true
            return
        }
        begin(total: ids.count, consensus: true, estimate: estimate)
        failedIDs = []
        lastFailure = nil
        let hotwords = settings.hotwords
        let context = settings.contextPrompt
        task = Task { [weak self] in
            guard let self else { return }
            let completed = await self.consensusLoop(
                ids: ids, key: key, hotwords: hotwords, context: context)
            if completed {
                let failed = self.failedIDs.count
                self.message = failed == 0 ? nil
                    : "\(failed) clip\(failed == 1 ? "" : "s") couldn't be labeled — Retry runs just those. Last error: \(self.lastFailure ?? "unknown")"
            }
            self.finish()
        }
    }

    private enum Outcome {
        case labeled(String, GroundTruthClient.ConsensusResult)
        case failed(String, Error)
        case skipped(String)
    }

    private struct Job {
        let id: String
        let url: URL
        let typed: String
    }

    /// A sliding window of `LabelEstimate.concurrency` clips. A failed clip
    /// is counted and the run moves on; only a key problem stops it.
    private func consensusLoop(ids: [String], key: String, hotwords: String, context: String) async -> Bool {
        let byID = Dictionary(store.samples.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let jobs: [Job] = ids.compactMap { id in
            guard let sample = byID[id], let url = store.audioURL(sample) else { return nil }
            return Job(id: id, url: url, typed: sample.transcript)
        }
        total = jobs.count   // rows deleted since the click drop out
        var cursor = 0
        return await withTaskGroup(of: Outcome.self, returning: Bool.self) { group in
            while cursor < min(LabelEstimate.concurrency, jobs.count) {
                let job = jobs[cursor]
                cursor += 1
                inFlight.insert(job.id)
                group.addTask { await Self.consensusJob(job, key: key, hotwords: hotwords, context: context) }
            }
            while let outcome = await group.next() {
                switch outcome {
                case .labeled(let id, let result):
                    inFlight.remove(id)
                    applyConsensus(id: id, result, hotwords: hotwords, coalesced: true)
                    done += 1
                case .skipped(let id):
                    inFlight.remove(id)
                case .failed(let id, let error):
                    inFlight.remove(id)
                    if let stop = error as? GroundTruthClient.GroundTruthError, stop.stopsRun {
                        // A key problem or a dead backend fails every clip
                        // the same way — stop now, say why.
                        message = stop.localizedDescription
                        if case .backendDown = stop { needsKeyFix = false } else { needsKeyFix = true }
                        group.cancelAll()
                        return false
                    }
                    failedIDs.append(id)
                    lastFailure = error.localizedDescription
                    message = "Last failure: \(error.localizedDescription)"
                }
                if Task.isCancelled {
                    message = "Stopped — \(done.formatted()) labeled. Label everything picks up the rest."
                    group.cancelAll()
                    return false
                }
                if cursor < jobs.count {
                    let job = jobs[cursor]
                    cursor += 1
                    inFlight.insert(job.id)
                    group.addTask { await Self.consensusJob(job, key: key, hotwords: hotwords, context: context) }
                }
            }
            return true
        }
    }

    /// One clip, off the main actor: validate the audio, ask the backend.
    private nonisolated static func consensusJob(_ job: Job, key: String, hotwords: String,
                                                 context: String) async -> Outcome {
        do {
            _ = try validatedAudioSeconds(job.url)
            let result = try await GroundTruthClient().consensus(
                audioURL: job.url, apiKey: key, typed: job.typed,
                hotwords: hotwords, context: context)
            return .labeled(job.id, result)
        } catch is CancellationError {
            return .skipped(job.id)
        } catch let error as URLError where error.code == .cancelled {
            return .skipped(job.id)
        } catch {
            return .failed(job.id, error)
        }
    }

    /// Spelling pass + store. Human labels (`finalText`) are never touched —
    /// training already prefers them.
    private func applyConsensus(id: String, _ result: GroundTruthClient.ConsensusResult,
                                hotwords: String, coalesced: Bool) {
        let text = VocabularyCorrector.correct(result.text, hotwords: hotwords)
        store.setLLMTranscript(id: id, text: text, model: LabelScope.modelTag(chosen: result.chosen),
                               agreement: result.agreement, coalesced: coalesced)
        TranscriptDiffCache.remove(id: id)
        agreementSum += result.agreement
        agreementCount += 1
        agreementMean = agreementSum / Double(agreementCount)
        if result.agreement < LabelScope.lowAgreement { lowAgreementCount += 1 }
        lastPrompt = result.prompt
        lastPromptMeta = "Consensus · \(result.chosen)"
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
        let key = providers.apiKey(for: .openai)
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(sample.id) }
            do {
                if recipe == .consensus {
                    _ = try Self.validatedAudioSeconds(url)
                    let result = try await GroundTruthClient().consensus(
                        audioURL: url, apiKey: key, typed: sample.transcript,
                        hotwords: hotwords, context: context)
                    self.applyConsensus(id: sample.id, result, hotwords: hotwords, coalesced: false)
                } else {
                    let text = try await self.singleText(url: url, provider: provider, model: model)
                    self.store.setLLMTranscript(id: sample.id, text: text, model: model)
                    TranscriptDiffCache.remove(id: sample.id)
                }
            } catch {
                self.message = error.localizedDescription
                if case .fatal? = error as? GroundTruthClient.GroundTruthError { self.needsKeyFix = true }
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
    }

    /// One single-provider transcription: Whisper runs in-app on the
    /// WhisperKit registry (no backend, no key); everything else goes through
    /// the backend proxy with the user's Vocabulary and prompt.
    private func singleText(url: URL, provider: AssistantProvider, model: String) async throws -> String {
        _ = try Self.validatedAudioSeconds(url)
        if provider == .whisper {
            lastPrompt = "(none — the on-device Whisper judge takes no text prompt, so the vocabulary can't steer it yet; use the pencil for name fixes)"
            lastPromptMeta = "Whisper · \(model)"
            guard let text = await TranscriptionModel.shared.transcribe(url, model: model),
                  !text.isEmpty else {
                throw GroundTruthClient.GroundTruthError.server(
                    "Whisper \(model) isn't ready — download it above, or the clip was silent.")
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
            throw GroundTruthClient.GroundTruthError.server(
                "This recording can't be opened as audio — the file is broken. Delete the row.")
        }
        let seconds = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        guard seconds >= 0.3 else {
            throw GroundTruthClient.GroundTruthError.server(String(
                format: "This recording holds only %.2fs of audio — nothing to transcribe. Delete the row.",
                seconds))
        }
        return seconds
    }
}
