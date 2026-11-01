import Foundation

/// The training routes the Training page uses — `TrainingClient` in the app,
/// a scripted fake in the self-test.
protocol TrainingJobClient {
    func readiness() async throws -> TrainingReadiness
    func latest() async throws -> WhisperTrainingJob?
    func models() async throws -> [WhisperTrainingModel]
    func start(sourceModel: String, method: String, name: String?,
               maxRamGB: Double) async throws -> WhisperTrainingJob
    func resume(id: String) async throws -> WhisperTrainingJob
    func status(id: String) async throws -> WhisperTrainingJob
}

extension TrainingClient: TrainingJobClient {}

/// The Training page's state and its job state machine: readiness, the
/// latest job, the backend's checkpoint catalog, the form's choices, and the
/// one live poller. Owned by the page (`@StateObject`), so it starts fresh on
/// every visit and the poller stops when you leave.
@MainActor
final class TrainingJobModel: ObservableObject {
    /// The Balanced checkpoint — the default base model.
    static let defaultSourceModel = "large-v3-v20240930_626MB"

    @Published private(set) var readiness: TrainingReadiness?
    @Published private(set) var job: WhisperTrainingJob?
    @Published var jobError: String?
    @Published private(set) var checking = false
    @Published private(set) var trainingModels: [WhisperTrainingModel] = []
    @Published var selectedModel = TrainingJobModel.defaultSourceModel
    @Published var selectedMethod = TrainingMethod.hybrid
    /// Optional user-chosen name for the finished model (fine-tunes only —
    /// stock models keep their names). Empty → the timestamped default.
    @Published var customName = ""
    @Published var maxRamGB = 12.0

    private let client: TrainingJobClient
    /// A finished job installed a model — the pickers should list it.
    private let onModelsChanged: () -> Void
    private let sleep: (UInt64) async throws -> Void
    /// The one live job poller. Every appear used to start another, and none
    /// ever stopped while the job ran.
    private var pollTask: Task<Void, Never>?

    /// Poll cadence while a job runs, and the back-off after a failed poll.
    static let pollInterval: UInt64 = 2_000_000_000
    static let retryInterval: UInt64 = 3_000_000_000
    /// Consecutive failed polls before live updates give up.
    static let maxPollFailures = 5

    init(client: TrainingJobClient,
         onModelsChanged: @escaping () -> Void,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.client = client
        self.onModelsChanged = onModelsChanged
        self.sleep = sleep
    }

    var selectedTrainingModel: WhisperTrainingModel? {
        trainingModels.first { $0.id == selectedModel }
    }

    /// Page left: stop the live poller (the job itself keeps running).
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Job state machine

    /// `keepingError`: a failed start reports its own message — refreshing
    /// must not wipe it in the same turn (Oct 29: the refusal never drew).
    func refresh(keepingError: Bool = false) {
        guard !checking else { return }
        checking = true
        if !keepingError { jobError = nil }
        let client = client
        Task { @MainActor in
            defer { checking = false }
            do {
                async let ready = client.readiness()
                async let latest = client.latest()
                async let models = client.models()
                readiness = try await ready
                job = try await latest
                trainingModels = try await models
                // Keep the selection valid against whatever catalog the
                // backend actually serves.
                if !trainingModels.isEmpty, !trainingModels.contains(where: { $0.id == selectedModel }) {
                    selectedModel = trainingModels[0].id
                }
                if let job, job.isActive {
                    selectedModel = job.sourceModel
                    selectedMethod = job.method == "lora" ? TrainingMethod.hybrid : job.method
                    maxRamGB = job.maxRamGB
                }
                if let job, job.isActive { poll(job.id) }
                if job?.state == "done" { onModelsChanged() }
                if job?.state == "error", !keepingError { jobError = job?.error }
            } catch {
                if !keepingError { jobError = error.localizedDescription }
            }
        }
    }

    func start() {
        jobError = nil
        Task { @MainActor in
            do {
                let trimmedName = customName.trimmingCharacters(in: .whitespaces)
                let started = try await client.start(
                    sourceModel: selectedModel, method: selectedMethod,
                    name: trimmedName.isEmpty ? nil : trimmedName,
                    maxRamGB: maxRamGB)
                job = started
                poll(started.id)
            } catch {
                jobError = error.localizedDescription
                refresh(keepingError: true)
            }
        }
    }

    func resume(_ id: String) {
        jobError = nil
        Task { @MainActor in
            do {
                let resumed = try await client.resume(id: id)
                job = resumed
                poll(resumed.id)
            } catch {
                jobError = error.localizedDescription
                refresh(keepingError: true)
            }
        }
    }

    private func poll(_ id: String) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let latest = try await client.status(id: id)
                    failures = 0
                    job = latest
                    if !latest.isActive {
                        if latest.state == "done" {
                            onModelsChanged()
                            readiness = try? await client.readiness()
                        } else if let error = latest.error {
                            jobError = error
                        }
                        return
                    }
                    try await sleep(Self.pollInterval)
                } catch {
                    if Task.isCancelled { return }   // page closed: not an error
                    // One blip (server busy converting, a respawn) must not end
                    // live updates for an hour-long run.
                    failures += 1
                    if failures >= Self.maxPollFailures {
                        jobError = error.localizedDescription
                        return
                    }
                    try? await sleep(Self.retryInterval)
                }
            }
        }
    }

    // MARK: - Time estimates

    /// Seconds per eligible CLIP (every clip pads to Whisper's 30 s window,
    /// so cost barely depends on its length), measured on an M4 Air with
    /// turbo (large family): Oct 12 — 3.1 hybrid / 0.33 decoder s/clip/epoch —
    /// and Oct 29 under memory pressure — 5.5 / 0.8; the midpoint. Encoding is
    /// the one-off frozen-encoder pass. Other families scale by rough model
    /// size. The tail is merge + ANE conversion + install — rough, not a promise.
    private static let encodeSecondsPerClip = 2.5
    private static let epochSecondsPerClip: [String: Double] = [
        TrainingMethod.hybrid: 4.3, TrainingMethod.decoder: 0.6,
    ]
    private static let familyScale: [String: Double] = [
        "tiny": 0.05, "base": 0.1, "small": 0.3, "medium": 0.6, "large": 1,
    ]
    private static let tailMinutes: [String: Double] = [
        "tiny": 3, "base": 4, "small": 7, "medium": 14, "large": 26,
    ]

    /// Pre-run whole-pipeline estimate for the local methods (nil when there
    /// are no eligible clips or the family/method is unknown).
    var estimatedMinutes: Double? {
        guard let model = selectedTrainingModel,
              let clips = readiness?.eligibleCount, clips > 0,
              let scale = Self.familyScale[model.family],
              let epoch = Self.epochSecondsPerClip[selectedMethod]
        else { return nil }
        let sft = Double(clips) * scale * (Self.encodeSecondsPerClip + epoch * 3) / 60
        return sft + (Self.tailMinutes[model.family] ?? 5)
    }

    static func timeText(_ minutes: Double) -> String {
        if minutes < 1 { return "under a minute" }
        if minutes < 90 { return "≈ \(Int(minutes.rounded())) min" }
        return String(format: "≈ %.1f h", minutes / 60)
    }

    /// Live remaining-time readout from the job's own pace: elapsed since it
    /// was created, scaled by how much progress is left. Silent for the first
    /// 30 s and the first few percent — early rates are noise.
    static func etaText(_ job: WhisperTrainingJob) -> String? {
        guard job.progress > 0.04, job.progress < 0.99,
              let started = job.createdAt else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 30 else { return nil }
        let remaining = elapsed * (1 - job.progress) / job.progress / 60
        return "\(timeText(remaining)) left"
    }
}
