import Foundation

/// How a load behaves once its model is resident.
struct LoadOptions {
    /// Warm up right after the load (when the tier warms and no dictation is
    /// waiting). The installer's prepare step and the benches turn it off:
    /// they warm — or measure cold — themselves.
    var warmsUp = true

    static let standard = LoadOptions()
    static let noWarmUp = LoadOptions(warmsUp: false)
}

/// Set when a model load finishes (MainActor-only).
@MainActor private final class LoadFlag { var done = false }

/// Loading, for every engine: one load per model, the hard timeout, the
/// cooldown after a failure, the interim copy that serves while a slow
/// Neural Engine compile runs, and the post-load warm-up. The engine's own
/// part is its `ModelLoader`'s `LoadPlan`.
///
/// Loading runs in the **background** and an already-loaded model keeps
/// serving until the new one is ready — the app never freezes on a switch.
/// A live per-model status (the engine's load stage / Ready / Failed) plus
/// the timeout mean it never sits on a silent, stuck spinner.
@MainActor
final class ModelLoads {
    /// 600s: a cold Neural Engine compile after a macOS update or a
    /// purged cache measured ~145s twice (Sep 29, Oct 7) — 150s was a
    /// coin flip, and a timeout leaves the model failed.
    nonisolated static let timeoutSeconds: UInt64 = 600
    /// After a failed load, holds don't start another for this long: each
    /// retry was a fresh up-to-600s wait, and a timed-out load can't be
    /// stopped — every hold stacked another one in RAM.
    nonisolated static let failedLoadCooldownSeconds: TimeInterval = 300

    nonisolated static func inCooldown(failedAt: Date?, now: Date = Date()) -> Bool {
        failedAt.map { now.timeIntervalSince($0) < failedLoadCooldownSeconds } ?? false
    }

    private let residency: ResidencyManager
    private unowned let board: ModelStatusBoard
    private let loader: (String) -> ModelLoader
    private let report: FaultSink
    private let now: () -> Date
    /// Called whenever a model becomes able to serve (the real copy or an
    /// interim one) — AppDelegate switches over to it.
    var onModelReady: ((String) -> Void)?

    /// The one in-flight load per model. Everything that needs a model
    /// (selection, the hold-start prime, a dictation that arrives early)
    /// awaits THIS instead of starting its own — a duplicate load used to
    /// stall behind the first and lose the dictation.
    private var tasks: [String: Task<Void, Never>] = [:]
    /// When each model's last load failed (cleared on success or a
    /// Download / Re-download).
    private var failedAt: [String: Date] = [:]
    /// Dictations waiting on each model's load (they skip its warm-up).
    private var waiting: [String: Int] = [:]

    init(residency: ResidencyManager, board: ModelStatusBoard, report: FaultSink,
         now: @escaping () -> Date = Date.init, loader: @escaping (String) -> ModelLoader) {
        self.residency = residency
        self.board = board
        self.report = report
        self.now = now
        self.loader = loader
    }

    func isRunning(_ model: String) -> Bool { tasks[model] != nil }
    func task(_ model: String) -> Task<Void, Never>? { tasks[model] }
    func dictationsWaiting(_ model: String) -> Int { waiting[model, default: 0] }

    /// `model` failed to load recently — don't start another load yet.
    func isCoolingDown(_ model: String) -> Bool { Self.inCooldown(failedAt: failedAt[model], now: now()) }

    /// Asking again (Download / Re-download) is an explicit retry.
    func clearFailure(_ model: String) { failedAt[model] = nil }

    /// Start `model`'s load, or join the one already running.
    func loadShared(_ model: String, options: LoadOptions = .standard) async {
        if let running = tasks[model] { await running.value; return }
        guard !isCoolingDown(model) else { return }
        // The task clears its own entry before anyone it wakes runs, so no
        // waiter (e.g. `redownload`) can find and re-join a finished load.
        let task = Task {
            await self.load(model, options)
            self.tasks[model] = nil
        }
        tasks[model] = task
        await task.value
    }

    /// A dictation is waiting for `model` — join its load (or start it) and
    /// suppress the post-load warm-up: the waiting dictation IS the first
    /// decode, and a warm-up racing it on the same freshly compiled model is
    /// exactly what we don't want. True when ready.
    func awaitAsDictation(_ model: String) async -> Bool {
        waiting[model, default: 0] += 1
        defer { waiting[model, default: 1] -= 1 }
        // Start (or join) the load, but return the moment the model can serve:
        // a CPU copy can land long before a slow Neural Engine compile ends.
        let loading = LoadFlag()
        Task { await self.loadShared(model); loading.done = true }
        while !residency.isResident(model), !loading.done {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return residency.isResident(model)
    }

    /// Load a downloaded/bundled model in the background (with a live stage +
    /// timeout). Swaps it in as a resident model only when it's fully ready,
    /// so anything already loaded keeps serving meanwhile.
    private func load(_ model: String, _ options: LoadOptions) async {
        guard let plan = loader(model).plan(model) else {
            board.setStatus(.notDownloaded, for: model)
            return
        }
        residency.beginLoad(model)
        board.setStatus(.preparing(plan.firstStage), for: model)
        Log.stt("load begin \(model) (\(plan.detail))")
        let t0 = Date()

        let interim = plan.interim.map { interim in
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interim.after * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.serveInterim(model, interim.load, since: t0)
            }
        }
        defer { interim?.cancel() }
        let stage: @MainActor (String) -> Void = { [weak self] stage in
            guard let self, self.residency.isLoading(model),
                  !self.residency.isResident(model) else { return }   // a CPU copy is serving
            self.board.setStatus(.preparing(stage), for: model)      // live stage
            Log.stt("stage \(model): \(stage)")
        }

        do {
            let recognizer = try await withTimeout(seconds: Self.timeoutSeconds) { try await plan.load(stage) }
            let replacedInterim = residency.isResident(model)
            residency.install(recognizer, for: model)
            residency.endLoad(model)
            failedAt[model] = nil
            if replacedInterim { Log.event("\(model): Neural Engine copy ready — replaced the CPU copy") }
            residency.markUsed()   // a fresh load is use — Feather keeps it its full window
            residency.noteLoaded(model, seconds: Date().timeIntervalSince(t0))
            board.setStatus(.ready, for: model)
            onModelReady?(model)
            Log.stt(String(format: "READY \(model) in %.1fs (resident: \(residency.resident.keys.sorted()))",
                           Date().timeIntervalSince(t0)))
            Log.event(String(format: "model ready: %@ in %.1fs%@", model, Date().timeIntervalSince(t0),
                             dictationsWaiting(model) > 0 ? " (a dictation is waiting)" : ""))
            // Immediately push the compiled graph through one tiny decode so
            // the FIRST real dictation pays inference only, not residency
            // (skipped on the Feather tier — its ethos is no idle spend).
            if residency.warmsAfterLoad(options, dictationsWaiting: dictationsWaiting(model)) {
                residency.warmUp(model)
            }
        } catch is TimeoutError {
            residency.endLoad(model)
            if residency.isResident(model) {
                Log.event("\(model): Neural Engine load timed out — staying on the CPU copy")
                board.setStatus(.ready, for: model)
                return
            }
            Log.event("model load TIMED OUT: \(model)")
            failedAt[model] = now()
            board.setStatus(.failed(plan.copy.timedOutStatus), for: model)
            report("speech model", plan.copy.timedOutReport, detail: "model \(model)")
            Log.stt("TIMEOUT loading \(model)")
        } catch {
            residency.endLoad(model)
            if residency.isResident(model) {
                Log.event("\(model): Neural Engine load failed — staying on the CPU copy")
                board.setStatus(.ready, for: model)
                return
            }
            failedAt[model] = now()
            board.setStatus(.failed(error.localizedDescription), for: model)
            Log.stt("FAILED loading \(model) — \(error)")
            NSLog("Slive: \(plan.copy.engine) load failed — \(error)")
            report("speech model", plan.copy.failedReport, error: error, detail: "model \(model)")
        }
    }

    /// Load `model`'s interim (CPU) copy and serve from it while its Neural
    /// Engine load is still compiling. Dropped if the real copy lands first.
    private func serveInterim(_ model: String, _ load: @MainActor () async -> (any Recognizer)?,
                              since t0: Date) async {
        guard residency.isLoading(model), !residency.isResident(model) else { return }
        Log.event("\(model): Neural Engine still compiling — loading a CPU copy meanwhile")
        guard let copy = await load(), residency.isLoading(model), !residency.isResident(model) else { return }
        residency.install(copy, for: model)
        board.setStatus(.ready, for: model)
        onModelReady?(model)
        Log.event(String(format: "model ready on CPU: %@ in %.1fs (Neural Engine still compiling)",
                         model, Date().timeIntervalSince(t0)))
    }
}
