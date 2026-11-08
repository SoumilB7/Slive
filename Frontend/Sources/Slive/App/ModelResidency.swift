import Foundation

/// Which speech models are in memory, and in what order they load. The
/// decisions are pure functions of the picks and the models' states
/// (`keep`, `plan`, `promotion`, `continuousWaits`, `fetchesContinuous`),
/// self-tested against the incidents in their comments; this class reads
/// the current values and carries the decisions out on TranscriptionModel.
@MainActor final class ModelResidency {
    private let whisper: ResidentModels
    private let settings: Settings

    /// The last dictation / continuous model that was READY. Kept resident
    /// while a newly picked model downloads + compiles, so dictation keeps
    /// working on it; replaced (and evicted) the moment the new one is ready.
    private(set) var servingDictationModel: String?
    private(set) var servingContinuousModel: String?

    /// Starts the background work a decision needs — a `Task` in the app;
    /// the self-tests run it themselves, in order.
    private let spawn: (@escaping @MainActor () async -> Void) -> Void

    init(whisper: ResidentModels, settings: Settings = .shared,
         spawn: @escaping (@escaping @MainActor () async -> Void) -> Void = { work in Task { @MainActor in await work() } }) {
        self.whisper = whisper
        self.settings = settings
        self.spawn = spawn
    }

    /// What the user picked, and what's serving now.
    struct Picks: Equatable {
        var dictation: String
        var continuous: String
        /// A continuous shortcut is set and switched on.
        var continuousOn: Bool
        var servingDictation: String?
        var servingContinuous: String?
    }

    /// The models' states as the decisions read them — TranscriptionModel
    /// live in the app, fixed tables in the self-tests. Read lazily, so the
    /// on-disk checks run only where the decision needs them.
    struct States {
        let isReady: (String) -> Bool
        let status: (String) -> TranscriptionModel.Status
        let isDownloaded: (String) -> Bool
    }

    /// What `refresh` loads after the eviction.
    enum Plan: Equatable {
        /// Load the launch stand-in first; re-plan once it's ready or failed.
        case standIn(String)
        /// Select dictation, then `continuous` (unless dictation is then
        /// loading — see `continuousWaits`), then fetch the continuous model
        /// if it was never downloaded (`fetchesContinuous`).
        case dictationFirst(dictation: String, continuous: String?, ensureContinuousDownloaded: Bool)
    }

    // MARK: - Running it

    private var picks: Picks {
        let s = settings
        let continuousOn = (s.streamHoldOn && s.streamHotkey != nil)
            || (s.streamToggleOn && s.streamToggleHotkey != nil)
        return Picks(dictation: s.whisperModel, continuous: s.continuousModel,
                     continuousOn: continuousOn,
                     servingDictation: servingDictationModel,
                     servingContinuous: servingContinuousModel)
    }

    private var states: States {
        let w = whisper
        return States(isReady: { w.isReady($0) }, status: { w.status(for: $0) },
                      isDownloaded: { w.isDownloaded($0) })
    }

    /// Keep exactly the models that are in use resident: dictation's always,
    /// continuous's only while its shortcut is set (same name = one shared
    /// instance). Everything else is evicted from RAM/ANE.
    func refresh() {
        forgetFailedDownloadsOfOldPicks()
        let picks = self.picks
        whisper.retainModels(Self.keep(picks, states))
        // Planned on the states AFTER the eviction, as it always read them.
        switch Self.plan(picks, states) {
        case .standIn(let standIn):
            whisper.select(standIn)
            // Ready or failed, Whisper goes next.
            spawn { [weak self] in
                _ = await self?.whisper.awaitReady(standIn)
                self?.refresh()
            }
            whisper.applySpeedTier(tierPicked: false)
        case .dictationFirst(let dictation, let continuous, let ensureContinuousDownloaded):
            whisper.select(dictation)
            if let continuous, !Self.continuousWaits(forDictation: whisper.status(for: dictation)) {
                whisper.select(continuous)
            }
            if ensureContinuousDownloaded { downloadContinuousModelIfNeeded() }
            whisper.applySpeedTier(tierPicked: false)   // arm (or disarm) the Feather-tier idle unload
        }
    }

    /// A model finished loading: switch to it if it's the current pick,
    /// then drop whatever it replaced.
    func modelReady(_ model: String) {
        let picks = self.picks
        let promoted = Self.promotion(ready: model, picks, states)
        if let dictation = promoted.dictation {
            servingDictationModel = dictation
            if promoted.isStandIn {
                Log.event("dictating on \(model) until \(picks.dictation) is ready")
            }
        }
        if let continuous = promoted.continuous { servingContinuousModel = continuous }
        refresh()
    }

    /// A load failed. When it was the dictation pick's, re-plan: the
    /// continuous model was waiting behind it (`continuousWaits`) and nothing
    /// else would start it, and a Parakeet stand-in can now serve dictation.
    func modelFailed(_ model: String) {
        guard model == settings.whisperModel else { return }
        refresh()
    }

    /// Back-to-back failed downloads of the dictation pick, in memory (a
    /// relaunch starts over).
    private var failedDownloads: (model: String, count: Int)?

    /// Failed downloads of the dictation pick in a row before residency
    /// re-plans around it. One is often a blip the retry fixes; the second
    /// says the pick won't arrive soon, so a downloaded Parakeet stands in.
    static let failedDownloadsBeforeStandIn = 2

    /// A download ended. The dictation pick's failures count up (a success
    /// or another model's download changes nothing for it); the second in a
    /// row re-plans as a failed load does. The continuous pick isn't
    /// counted: a stream already runs on whatever model is loaded, and each
    /// stream press retries its download.
    func downloadFinished(_ model: String, ok: Bool) {
        guard model == settings.whisperModel else { return }
        if ok {
            failedDownloads = nil
            return
        }
        let count = failedDownloads?.model == model ? failedDownloads!.count + 1 : 1
        failedDownloads = (model, count)
        if count >= Self.failedDownloadsBeforeStandIn {
            Log.event("\(model) failed to download \(count) times in a row — re-planning residency")
            refresh()
        }
    }

    /// The streak belongs to one pick: another pick (or picking back)
    /// starts over.
    private func forgetFailedDownloadsOfOldPicks() {
        if let failed = failedDownloads, failed.model != settings.whisperModel { failedDownloads = nil }
    }

    /// Continuous mode is on (a shortcut is set) but its model was never
    /// downloaded — fetch it. Turning continuous on IS asking for it. A
    /// failed download is retried only on `retryFailed` (a live-typing
    /// press): settings refreshes would restart it nonstop and hide the
    /// failure. True when a download is running or was just started.
    @discardableResult
    func downloadContinuousModelIfNeeded(retryFailed: Bool = false) -> Bool {
        let model = settings.continuousModel
        guard !whisper.isDownloaded(model) else { return false }
        switch Self.fetchesContinuous(status: whisper.status(for: model), retryFailed: retryFailed) {
        case .running: return true
        case .no: return false
        case .start: break
        }
        Log.event("continuous model \(model) not downloaded — downloading it")
        let whisper = self.whisper
        spawn { await whisper.download(model, options: .standard) }
        return true
    }

    // MARK: - Decisions (pure)

    /// Resident set: the picks, plus the previous pick until its replacement
    /// is ready.
    static func keep(_ p: Picks, _ s: States) -> Set<String> {
        var want: Set<String> = [p.dictation]
        if p.continuousOn { want.insert(p.continuous) }
        // Keep the previous pick resident until its replacement is ready.
        var keep = want
        if let old = p.servingDictation, !s.isReady(p.dictation) { keep.insert(old) }
        if p.continuousOn, let old = p.servingContinuous,
           !s.isReady(p.continuous) { keep.insert(old) }
        return keep
    }

    static func plan(_ p: Picks, _ s: States) -> Plan {
        let dictation = p.dictation
        // Launch stand-in. When macOS has discarded Whisper's compiled copy
        // (it does within about a day) its Neural Engine compile takes 60–90s,
        // and macOS compiles one model at a time — so nothing could be
        // dictated for over a minute after launch (Oct 31: 70s). Parakeet
        // compiles in ~10s: load it FIRST and dictate on it until Whisper is
        // ready (`onModelReady` re-runs this and starts Whisper right after).
        // Only when nothing else can serve and Whisper hasn't started loading.
        if let standIn = launchStandIn(for: dictation, continuous: p.continuous, s), !s.isReady(dictation),
           !s.isReady(standIn), p.servingDictation.map({ !s.isReady($0) }) ?? true {
            switch (s.status(dictation), s.status(standIn)) {
            case (.preparing, _), (.downloading, _): break   // already compiling — queueing behind it helps nobody
            case (_, .failed): break                          // no stand-in; Whisper as usual
            default: return .standIn(standIn)
            }
        }
        // Dictation first. macOS compiles one model at a time for the Neural
        // Engine, and after its compile cache is purged (low disk space, OS
        // update) a cold compile takes minutes — the continuous model must
        // not make the dictation model wait in line (Sep 29: Parakeet's 18s
        // compile ran first, dictation was ready 2m25s after launch).
        // `onModelReady` re-runs this, so continuous loads right after.
        let continuous = p.continuousOn && p.continuous != dictation ? p.continuous : nil
        return .dictationFirst(dictation: dictation, continuous: continuous,
                               ensureContinuousDownloaded: p.continuousOn)
    }

    /// The continuous model waits while dictation's select left it loading
    /// (read right after the select, which marks a load `.preparing` at once).
    static func continuousWaits(forDictation status: TranscriptionModel.Status) -> Bool {
        switch status {
        case .preparing, .downloading: return true   // wait for dictation
        default: return false
        }
    }

    /// A downloaded Parakeet model to dictate on while a Whisper pick compiles
    /// — the continuous model if it's one, else any downloaded Parakeet.
    static func launchStandIn(for dictation: String, continuous: String, _ s: States) -> String? {
        guard ModelCatalog.engine(of: dictation) == .whisper else { return nil }
        // A candidate whose load failed is passed over for the next one.
        let candidates = [continuous] + ModelCatalog.ids(of: .parakeet)
        return candidates.first {
            ModelCatalog.engine(of: $0) == .parakeet && s.isDownloaded($0) && !isFailed(s.status($0))
        }
    }

    private static func isFailed(_ status: TranscriptionModel.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    /// Who serves once `model` is ready: the pick, or the launch stand-in
    /// while the pick is still compiling.
    struct Promotion: Equatable {
        var dictation: String?
        var continuous: String?
        var isStandIn = false
    }

    static func promotion(ready model: String, _ p: Picks, _ s: States) -> Promotion {
        var out = Promotion()
        if model == p.dictation { out.dictation = model }
        // The launch stand-in is ready first: dictation runs on it until
        // the picked model has compiled.
        else if model == launchStandIn(for: p.dictation, continuous: p.continuous, s),
                !s.isReady(p.dictation) {
            out.dictation = model
            out.isStandIn = true
        }
        if model == p.continuous { out.continuous = model }
        return out
    }

    /// Whether an undownloaded continuous model gets fetched now.
    enum Fetch: Equatable { case running, no, start }

    static func fetchesContinuous(status: TranscriptionModel.Status, retryFailed: Bool) -> Fetch {
        switch status {
        case .downloading: return .running
        case .failed where !retryFailed: return .no
        default: return .start
        }
    }
}

/// What residency drives: `TranscriptionModel` in the app, a simulated
/// loader in the self-tests (so `refresh` itself runs on every config).
@MainActor protocol ResidentModels: AnyObject {
    func isReady(_ model: String) -> Bool
    func status(for model: String) -> ModelStatus
    func isDownloaded(_ model: String) -> Bool
    func retainModels(_ keep: Set<String>)
    func select(_ model: String)
    func awaitReady(_ model: String) async -> Bool
    func applySpeedTier(tierPicked: Bool)
    func download(_ model: String, options: LoadOptions) async
}

extension TranscriptionModel: ResidentModels {}
