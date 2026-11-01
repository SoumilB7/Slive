import Foundation

/// The residency side of a `SpeedTier`, as the values the decisions read.
struct ResidencyPolicy: Equatable {
    /// Models stay resident (vs released under memory pressure).
    var pins: Bool
    /// Release idle models when macOS reports memory pressure (Feather).
    var releasesUnderPressure: Bool
    /// Warm a model that's gone cold at hold start.
    var primesOnHold: Bool
    /// Run a warm-up decode right after a model loads.
    var warmsAfterLoad: Bool

    init(pins: Bool, releasesUnderPressure: Bool, primesOnHold: Bool, warmsAfterLoad: Bool) {
        self.pins = pins
        self.releasesUnderPressure = releasesUnderPressure
        self.primesOnHold = primesOnHold
        self.warmsAfterLoad = warmsAfterLoad
    }

    init(_ tier: SpeedTier) {
        self.init(pins: tier.pinsModels, releasesUnderPressure: tier.releasesUnderPressure,
                  primesOnHold: tier.primesOnHold, warmsAfterLoad: tier.warmsAfterLoad)
    }
}

/// The models in memory and the work running on them: which are resident,
/// which are loading, warm-ups and real decodes per model, and the Feather
/// tier's release under memory pressure.
///
/// Dictation and continuous dictation are fully independent, each with its
/// OWN model, so this is keyed by model id: when both point at the same id
/// exactly ONE instance is resident (shared by key); when they differ, two
/// load side by side. `retain` evicts anything no longer referenced so RAM
/// never grows unbounded on a switch.
@MainActor
final class ResidencyManager {
    /// One entry == one resident model in RAM.
    private(set) var resident: [String: any Recognizer] = [:]
    /// Models being prepared in the background right now.
    private(set) var loading: Set<String> = []
    /// Last use of any model: stamped at the start of every decode, at hold
    /// start and when a load finishes. Drives the battery-mode idle unload
    /// and the cold-graph priming heuristic. (Stamping only decodes let
    /// Feather drop a model a minute after a 90s compile that followed a
    /// long idle, or between the hold-start reload and the release decode.)
    private(set) var lastUse: Date
    /// The in-flight warm-up per model — warming one model never skips
    /// warming another.
    private var warmUps: [String: Task<Void, Never>] = [:]
    /// Real decodes running per model (absent = none).
    private var decodesInFlight: [String: Int] = [:]
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// Models Feather released; the next load of one is timed as a reload.
    private var releasedByFeather: Set<String> = []
    /// Set once a Feather reload proved slow (a full Neural Engine recompile):
    /// Feather then stops releasing models, and the speed graph says why.
    /// Cleared when the user picks a tier again.
    private(set) var keepsModelsReason: String? {
        didSet { onKeepsModelsReasonChange?(keepsModelsReason) }
    }
    var onKeepsModelsReasonChange: ((String?) -> Void)?

    /// A release must not land mid-session: the model has been idle this long.
    nonisolated static let pressureReleaseIdleSeconds: TimeInterval = 60
    /// A reload slower than this was a recompile, not a cache hit (~3s).
    nonisolated static let slowReloadSeconds: TimeInterval = 10
    /// A hold after this long idle re-warms a resident model (tiers that prime).
    nonisolated static let coldAfterSeconds: TimeInterval = 300
    /// A warm-up that hasn't returned by now never will.
    nonisolated static let warmUpTimeoutSeconds: UInt64 = 60

    /// Read at each decision, so a tier change applies from the next one.
    private let policy: () -> ResidencyPolicy
    /// The bundled warm-up speech (read on first use).
    private let warmUpAudio: () -> [Float]?
    private let now: () -> Date
    /// Whether a live stream is running — Feather never releases under one.
    var isLiveRunning: () -> Bool = { false }

    init(policy: @escaping () -> ResidencyPolicy, warmUpAudio: @escaping () -> [Float]?,
         now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.warmUpAudio = warmUpAudio
        self.now = now
        lastUse = now()
    }

    // MARK: - What's resident

    func isResident(_ model: String) -> Bool { resident[model] != nil }
    func recognizer(_ model: String) -> (any Recognizer)? { resident[model] }
    func isLoading(_ model: String) -> Bool { loading.contains(model) }
    func isWarming(_ model: String) -> Bool { warmUps[model] != nil }
    func decodesRunning(_ model: String) -> Int { decodesInFlight[model] ?? 0 }

    func install(_ recognizer: any Recognizer, for model: String) { resident[model] = recognizer }
    func evict(_ model: String) { resident.removeValue(forKey: model) }
    func beginLoad(_ model: String) { loading.insert(model) }
    func endLoad(_ model: String) { loading.remove(model) }

    /// A model was used (decode, hold start, fresh load).
    func markUsed() { lastUse = now() }

    /// Evict any loaded model NOT in `keep` (and never `live`), freeing its
    /// Core ML / Neural Engine resources. Returns what was evicted.
    @discardableResult
    func retain(_ keep: Set<String>, live: String?) -> [String] {
        let evicted = resident.keys.filter { !keep.contains($0) && $0 != live }
        for key in evicted {
            resident.removeValue(forKey: key)
            loading.remove(key)
        }
        return evicted
    }

    /// Release ALL loaded models (quit): dropping the instances
    /// deterministically frees their Core ML / Neural Engine resources first,
    /// and abandons any in-flight background loads so nothing lingers.
    func removeAll() {
        resident.removeAll()
        loading.removeAll()
    }

    // MARK: - Decodes and warm-ups

    /// Mark a real decode of `model` running, then wait out its in-flight
    /// warm-up: one WhisperKit instance isn't built for concurrent
    /// transcribes, and a warm-up sharing the pipe is the likely cause of
    /// "the first decode on a just-loaded model came back empty" (Oct 7).
    /// The wait is at most the warm-up already running; none starts while
    /// the decode is counted. Pair with `endDecode`.
    func beginDecode(_ model: String) async {
        decodesInFlight[model, default: 0] += 1
        if let warming = warmUps[model] { await warming.value }
    }

    func endDecode(_ model: String) {
        let left = decodesInFlight[model, default: 1] - 1
        decodesInFlight[model] = left > 0 ? left : nil
    }

    /// One real decode so the first dictation pays inference only. It must
    /// be SPEECH: 0.5s of silence (the old warm-up) is skipped by Whisper in
    /// ~10ms, leaving the first real dictation to pay ~1.3s of one-time setup
    /// (`--bench-coldstart`: first dictation 2.46s vs 1.15s warm; with a
    /// speech warm-up it's 1.18s). The bundled WarmUp.wav is 4.8s of macOS
    /// text-to-speech. Fire-and-forget; one at a time per model, and skipped
    /// while a real decode runs on it (that decode IS the warm-up).
    func warmUp(_ model: String) {
        guard warmUps[model] == nil, decodesInFlight[model] == nil,
              let recognizer = resident[model], let audio = recognizer.warmUpClip(bundled: warmUpAudio()) else { return }
        warmUps[model] = Task {
            let t0 = Date()
            // Bounded: a real decode waits on this (`beginDecode`).
            let done = (try? await withTimeout(seconds: Self.warmUpTimeoutSeconds, what: "warm-up") {
                _ = try? await recognizer.warmUp(audio)
            }) != nil
            warmUps[model] = nil
            Log.stt(String(format: "warm-up of %@ %@ after %.2fs", model,
                           done ? "done" : "TIMED OUT", Date().timeIntervalSince(t0)))
        }
    }

    /// What a hold start needs for `model`.
    enum Prime: Equatable {
        /// Not resident (Feather released it): load it now, overlapped with the hold.
        case load
        /// Resident but cold: a warm-up started.
        case warmed
        case nothing
    }

    /// Called at hold-start: if the model was unloaded (Feather tier) it
    /// needs loading NOW — overlapped with the user speaking — and, on tiers
    /// that prime, if the graph has merely gone cold (minutes since the last
    /// decode), run a warmup in parallel with the hold so release pays
    /// inference only.
    func primeIfCold(_ model: String) -> Prime {
        let idle = now().timeIntervalSince(lastUse)
        // A hold is use: Feather must not drop the model between this
        // hold-start (re)load and the release decode. Also debounces repeat
        // holds while warming.
        lastUse = now()
        if !isResident(model) { return .load }
        guard policy().primesOnHold, idle > Self.coldAfterSeconds else { return .nothing }
        warmUp(model)
        return .warmed
    }

    /// Whether a load that just finished should warm up: the tier warms,
    /// the caller didn't opt out, and no dictation is waiting (that
    /// dictation IS the first decode).
    func warmsAfterLoad(_ options: LoadOptions, dictationsWaiting: Int) -> Bool {
        policy().warmsAfterLoad && options.warmsUp && dictationsWaiting == 0
    }

    // MARK: - Feather (release under memory pressure)

    /// Apply the residency side of the selected SpeedTier. Pinned tiers just
    /// disarm the listener; Feather listens for macOS memory pressure and
    /// releases idle models when it comes — `primeIfCold` reloads on the next
    /// hold, overlapped with the user speaking, and the file path self-heals
    /// regardless. `tierPicked`: the user just chose a tier, so a previous
    /// "reloads are slow here" verdict is re-tested.
    func applyPolicy(tierPicked: Bool = false) {
        if tierPicked { keepsModelsReason = nil }
        guard policy().releasesUnderPressure else {
            memoryPressure?.cancel()
            memoryPressure = nil
            return
        }
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.releaseUnderPressure() }
        }
        source.resume()
        memoryPressure = source
    }

    /// Release every idle model (memory pressure on Feather). Returns what
    /// was released.
    @discardableResult
    func releaseUnderPressure() -> [String] {
        guard policy().releasesUnderPressure,
              keepsModelsReason == nil,
              now().timeIntervalSince(lastUse) > Self.pressureReleaseIdleSeconds,
              !isLiveRunning() else { return [] }
        // Never pull a model out from under its own load, warm-up or decode.
        let busy = loading.union(warmUps.keys).union(decodesInFlight.keys)
        let idle = Set(resident.keys).subtracting(busy)
        guard !idle.isEmpty else { return [] }
        Log.event("Feather: memory pressure — released \(idle.sorted().joined(separator: ", "))")
        // Statuses stay .ready on purpose: the models are still downloaded and
        // one hold away — every decode path load-on-demands through
        // `primeIfCold` / `transcribe(url:)`.
        for key in idle { resident.removeValue(forKey: key) }
        releasedByFeather.formUnion(idle)
        return idle.sorted()
    }

    /// A model finished loading in `seconds`. If Feather had released it and
    /// the reload was a recompile, stop releasing: on this Mac every release
    /// would cost that wait again.
    func noteLoaded(_ model: String, seconds: Double) {
        guard releasedByFeather.remove(model) != nil, seconds > Self.slowReloadSeconds else { return }
        keepsModelsReason = String(
            format: "Reloads are slow here (%.0f s), so models stay loaded.", seconds)
        Log.event(String(format: "Feather: reload of %@ took %.0fs — no longer releasing models", model, seconds))
    }
}
