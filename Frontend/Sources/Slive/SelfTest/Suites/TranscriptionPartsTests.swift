import AVFoundation
import Foundation
import SliveTestKit
import WhisperKit

/// The parts behind `TranscriptionModel`, with fake recognizers, loaders and
/// storage: residency + Feather decisions, load cooldown and the CPU-copy
/// handover, decode bookkeeping, downloads, and storage completeness rules
/// against a temp dir. Async parts run on the main run loop (`settle`).
@MainActor
enum TranscriptionPartsTests {
    static let suite = TestSuite(name: "Transcription parts") { t in
        print("[Transcription parts]")
        policy(&t)
        residency(&t)
        loads(&t)
        decoder(&t)
        downloads(&t)
        storage(&t)
        live(&t)
    }

    // MARK: - Residency policy

    private static func policy(_ t: inout Checks) {
        let instant = ResidencyPolicy(.instant), feather = ResidencyPolicy(.feather)
        t.check(instant.pins && !instant.releasesUnderPressure && instant.primesOnHold && instant.warmsAfterLoad,
                "Instant: pinned, primes on hold, warms after load")
        t.check(!feather.pins && feather.releasesUnderPressure && !feather.primesOnHold && !feather.warmsAfterLoad,
                "Feather: releases under pressure, never primes or warms")
        t.check(SpeedTier.allCases.allSatisfy {
            let p = ResidencyPolicy($0)
            return p.pins == $0.pinsModels && p.releasesUnderPressure == $0.releasesUnderPressure
                && p.primesOnHold == $0.primesOnHold && p.warmsAfterLoad == $0.warmsAfterLoad
        }, "policy mirrors every tier's knobs")
    }

    // MARK: - Residency + Feather

    private static func residency(_ t: inout Checks) {
        let clock = Clock()
        var tier = SpeedTier.feather
        let r = ResidencyManager(policy: { ResidencyPolicy(tier) }, warmUpAudio: { [0.1] }, now: clock.now)
        let a = FakeRecognizer(), b = FakeRecognizer()
        r.install(a, for: "a")
        r.install(b, for: "b")
        clock.advance(30)
        t.equal(r.releaseUnderPressure(), [], "Feather: nothing released within a minute of use")
        clock.advance(31)
        var live = true
        r.isLiveRunning = { live }
        t.equal(r.releaseUnderPressure(), [], "Feather: never releases under a live stream")
        live = false
        r.beginLoad("b")
        t.equal(r.releaseUnderPressure(), ["a"], "Feather: releases idle models, never one that's loading")
        t.check(!r.isResident("a") && r.isResident("b"), "released model leaves residency")
        r.endLoad("b")
        tier = .relaxed
        t.equal(r.releaseUnderPressure(), [], "pinned tiers never release")

        tier = .feather
        r.noteLoaded("a", seconds: 3)
        t.check(r.keepsModelsReason == nil, "a fast reload keeps Feather releasing")
        r.evict("b")
        r.install(b, for: "b")
        clock.advance(61)
        t.equal(r.releaseUnderPressure(), ["b"], "released again after idle")
        var reported: String?
        r.onKeepsModelsReasonChange = { reported = $0 }
        r.noteLoaded("b", seconds: ResidencyManager.slowReloadSeconds + 5)
        t.check(r.keepsModelsReason != nil && reported == r.keepsModelsReason,
                "a slow reload (a recompile) stops Feather releasing, and says why")
        r.install(b, for: "b")
        clock.advance(61)
        t.equal(r.releaseUnderPressure(), [], "no release once reloads proved slow")
        tier = .relaxed
        r.applyPolicy(tierPicked: true)
        t.check(r.keepsModelsReason == nil && reported == nil, "picking a tier re-tests the verdict")

        // Hold-start priming.
        let p = ResidencyManager(policy: { ResidencyPolicy(tier) }, warmUpAudio: { [0.1] }, now: clock.now)
        t.equal(p.primeIfCold("x"), .load, "hold on a released model → load it now")
        p.install(FakeRecognizer(), for: "x")
        tier = .instant
        clock.advance(100)
        t.equal(p.primeIfCold("x"), .nothing, "warm graph → nothing to do")
        clock.advance(ResidencyManager.coldAfterSeconds + 1)
        t.equal(p.primeIfCold("x"), .warmed, "Instant: a cold graph warms at hold start")
        t.check(p.isWarming("x"), "the warm-up is running")
        tier = .snappy
        clock.advance(ResidencyManager.coldAfterSeconds + 1)
        t.equal(p.primeIfCold("x"), .nothing, "Snappy never primes on hold")

        // Warm-up after load.
        tier = .relaxed
        t.check(p.warmsAfterLoad(.standard, dictationsWaiting: 0), "load warms up on a warming tier")
        t.check(!p.warmsAfterLoad(.noWarmUp, dictationsWaiting: 0), "no-warm-up load option (benches, prepare)")
        t.check(!p.warmsAfterLoad(.standard, dictationsWaiting: 1), "a waiting dictation is the warm-up")
        tier = .feather
        t.check(!p.warmsAfterLoad(.standard, dictationsWaiting: 0), "Feather never warms after load")

        // Retain: evicts what's not kept, never the live model.
        let k = ResidencyManager(policy: { ResidencyPolicy(.relaxed) }, warmUpAudio: { nil })
        for id in ["keep", "live", "drop"] { k.install(FakeRecognizer(), for: id) }
        k.beginLoad("drop")
        t.equal(k.retain(["keep"], live: "live"), ["drop"], "retain evicts only the unreferenced model")
        t.check(k.isResident("keep") && k.isResident("live") && !k.isLoading("drop"), "kept + live stay resident")

        // No warm-up clip (Parakeet outside the bundle) → no warm-up at all.
        let silentClip = FakeRecognizer()
        silentClip.skipsWarmUpWithoutAudio = true
        k.install(silentClip, for: "quiet")
        k.warmUp("quiet")
        t.check(!k.isWarming("quiet"), "no warm-up clip → warm-up skipped")
    }

    // MARK: - Loads: cooldown, CPU copy, warm-up

    private static func loads(_ t: inout Checks) {
        let clock = Clock()
        let board = FakeBoard()
        let faults = FaultRecorder()
        let residency = ResidencyManager(policy: { ResidencyPolicy(.relaxed) }, warmUpAudio: { [0.1] })
        var plans: [String: LoadPlan] = [:]
        var loadCalls = 0
        let loads = ModelLoads(residency: residency, board: board, report: faults.sink, now: clock.now) { _ in
            FakeLoader { plans[$0] }
        }
        var ready: [String] = []
        loads.onModelReady = { ready.append($0) }

        // Failure → failed status, report, cooldown; no retry until it ends.
        plans["bad"] = plan { loadCalls += 1; throw CocoaError(.fileReadCorruptFile) }
        settle { await loads.loadShared("bad") }
        t.check(loadCalls == 1, "failed load ran once")
        if case .failed = board.status(for: "bad") { t.check(true, "failed load → Failed status") } else {
            t.check(false, "failed load → Failed status", "got \(board.status(for: "bad"))")
        }
        t.check(faults.titles == ["The fake model failed to load."], "failed load reported once", "\(faults.titles)")
        t.check(loads.isCoolingDown("bad"), "failed load → cooldown")
        settle { await loads.loadShared("bad") }
        t.equal(loadCalls, 1, "no new load during the cooldown")
        clock.advance(ModelLoads.failedLoadCooldownSeconds + 1)
        t.check(!loads.isCoolingDown("bad"), "cooldown ends")
        clock.advance(-ModelLoads.failedLoadCooldownSeconds - 1)
        loads.clearFailure("bad")
        settle { await loads.loadShared("bad") }
        t.equal(loadCalls, 2, "Download / Re-download clears the cooldown")

        // Nothing on disk → Not downloaded.
        settle { await loads.loadShared("missing") }
        t.equal(board.status(for: "missing"), .notDownloaded, "no plan → Not downloaded")

        // Success: one load for concurrent callers, ready, warm-up per policy.
        let good = FakeRecognizer()
        var goodCalls = 0
        plans["good"] = plan { goodCalls += 1; try await Task.sleep(nanoseconds: 50_000_000); return good }
        settle {
            async let first: Void = loads.loadShared("good")
            async let second: Void = loads.loadShared("good")
            _ = await (first, second)
        }
        t.equal(goodCalls, 1, "concurrent callers share one load")
        t.check(residency.recognizer("good") === good && board.status(for: "good") == .ready
                && ready == ["good"], "loaded model is resident, Ready, announced")
        t.check(residency.isWarming("good") || good.warmUps == 1, "load warms up after (warming tier)")

        let cold = FakeRecognizer()
        plans["cold"] = plan { cold }
        settle { await loads.loadShared("cold", options: .noWarmUp) }
        settle { try? await Task.sleep(nanoseconds: 20_000_000) }
        t.check(!residency.isWarming("cold") && cold.warmUps == 0, "noWarmUp load option skips the warm-up")

        // CPU copy: serves while the real load compiles, then is replaced.
        let cpu = FakeRecognizer(), ane = FakeRecognizer()
        plans["slow"] = plan(interimAfter: 0.05, interim: { cpu }) {
            try await Task.sleep(nanoseconds: 600_000_000); return ane
        }
        ready = []
        var midway: (any Recognizer)?
        var midStatus = ModelStatus.notDownloaded
        settle {
            let load = Task { await loads.loadShared("slow") }
            try? await Task.sleep(nanoseconds: 300_000_000)
            midway = residency.recognizer("slow")
            midStatus = board.status(for: "slow")
            await load.value
        }
        t.check(midway === cpu && midStatus == .ready, "slow compile → the CPU copy serves meanwhile")
        t.check(residency.recognizer("slow") === ane && ready == ["slow", "slow"],
                "the Neural Engine copy replaces the CPU copy")

        // A CPU copy that lands after the real one is dropped.
        let late = FakeRecognizer(), real = FakeRecognizer()
        plans["fast"] = plan(interimAfter: 0.02, interim: {
            try? await Task.sleep(nanoseconds: 300_000_000); return late
        }) { try await Task.sleep(nanoseconds: 100_000_000); return real }
        settle {
            await loads.loadShared("fast")
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        t.check(residency.recognizer("fast") === real, "a CPU copy that lands late is dropped")

        // Real load fails while a CPU copy serves → stay on the CPU copy.
        let fallback = FakeRecognizer()
        faults.titles = []
        plans["flaky"] = plan(interimAfter: 0.02, interim: { fallback }) {
            try await Task.sleep(nanoseconds: 200_000_000); throw CocoaError(.fileReadCorruptFile)
        }
        settle { await loads.loadShared("flaky") }
        t.check(residency.recognizer("flaky") === fallback && board.status(for: "flaky") == .ready
                && faults.titles.isEmpty && !loads.isCoolingDown("flaky"),
                "Neural Engine load fails → stays on the CPU copy, no failure")

        // A waiting dictation suppresses the warm-up.
        let waited = FakeRecognizer()
        plans["waited"] = plan { try await Task.sleep(nanoseconds: 50_000_000); return waited }
        let got = settle { await loads.awaitAsDictation("waited") }
        settle { try? await Task.sleep(nanoseconds: 20_000_000) }
        t.check(got == true && waited.warmUps == 0 && !residency.isWarming("waited"),
                "a dictation waiting on the load skips its warm-up")

        // The timing rule for the CPU copy (unchanged).
        let gb: UInt64 = 1 << 30
        t.check(WhisperLoader.cpuCopyDelay(model: "large-v3", physicalMemory: 8 * gb) >= 150
                && WhisperLoader.cpuCopyDelay(model: "base.en", physicalMemory: 8 * gb) == WhisperLoader.cpuCopyAfterSeconds,
                "CPU copy waits longer only for a large model on 8 GB")
    }

    // MARK: - Decoder bookkeeping

    private static func decoder(_ t: inout Checks) {
        let residency = ResidencyManager(policy: { ResidencyPolicy(.relaxed) }, warmUpAudio: { [0.1] })
        let metrics = DecodeMetricsStore(store: InMemoryStore())
        let faults = FaultRecorder()
        let decoder = SpeechDecoder(residency: residency, metrics: metrics, report: faults.sink, timeout: { _ in 1 })
        let m = FakeRecognizer()
        residency.install(m, for: "m")
        let fiveSeconds = [Float](repeating: 0.1, count: 80_000)

        t.check(settle { await decoder.transcribe(fiveSeconds, model: "absent") } == .some(nil),
                "not resident → nil")
        t.check(settle { await decoder.transcribe([Float](repeating: 0.1, count: SpeechDecoder.minSamples), model: "m") } == .some(nil)
                && m.calls == 0, "too short (<~0.33s) → skipped, never decoded")

        m.text = "hello there"
        t.equal(settle { await decoder.transcribe(fiveSeconds, model: "m") } ?? nil, "hello there", "decodes on the resident model")
        t.check(metrics.typicalDecode(for: "m") != nil, "a pure in-band decode calibrates")
        t.equal(residency.decodesRunning("m"), 0, "decode bookkeeping cleared")

        // A decode that never returns: timeout clears the in-flight count and reports.
        m.delay = 3_000_000_000
        let t0 = Date()
        let hung = settle { await decoder.transcribe(fiveSeconds, model: "m") }
        t.check(hung == .some(nil) && Date().timeIntervalSince(t0) < 2.5, "hung decode times out")
        t.equal(residency.decodesRunning("m"), 0, "timeout clears the in-flight decode")
        t.equal(faults.titles, ["A dictation's transcription never finished."], "timeout reported")
        m.delay = 0

        faults.titles = []
        m.error = CocoaError(.fileReadCorruptFile)
        _ = settle { await decoder.transcribe(fiveSeconds, model: "m") }
        m.error = CancellationError()
        _ = settle { await decoder.transcribe(fiveSeconds, model: "m") }
        t.equal(faults.titles, ["Transcribing a dictation failed."], "a failed decode is reported, a cancel isn't")
        m.error = nil

        // A real decode waits out the warm-up running on its model.
        m.events = []
        m.warmUpDelay = 200_000_000
        residency.warmUp("m")
        _ = settle { await decoder.transcribe(fiveSeconds, model: "m") }
        t.equal(m.events, ["warm start", "warm end", "decode"], "decode waits for the in-flight warm-up")
        m.warmUpDelay = 0

        // No warm-up starts while a decode runs.
        m.delay = 200_000_000
        let warmedDuring = settle { () -> Bool in
            let decode = Task { await decoder.transcribe(fiveSeconds, model: "m") }
            try? await Task.sleep(nanoseconds: 50_000_000)
            residency.warmUp("m")
            let warming = residency.isWarming("m")
            _ = await decode.value
            return warming
        }
        t.equal(warmedDuring, false, "warm-up skipped while a real decode runs")
        m.delay = 0

        // Files: an engine that doesn't read files gets the samples path.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("clip.wav")
        writeWAV(fiveSeconds, to: wav)
        m.calls = 0
        t.equal(settle { await decoder.transcribe(fileAt: wav, model: "m") } ?? nil, "hello there",
                "file on a sample engine → read and decoded")
        t.equal(m.calls, 1, "file path decoded once")
    }

    // MARK: - Downloads

    private static func downloads(_ t: inout Checks) {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let basket = ModelBasket(root: dir)
        let board = FakeBoard()
        let downloads = ModelDownloads(basket: basket, board: board)
        let storage = FakeStorage()
        let folder = dir.appendingPathComponent("m-folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storage.folder = folder

        let results = settle { () -> [Bool] in
            async let a = downloads.fetch("m", into: storage)
            async let b = downloads.fetch("m", into: storage)
            return await [a, b]
        }
        t.check(results == [true, true] && storage.fetches == 1, "one download per model, joined by every caller")
        t.check(ModelBasket.isStamped(folder), "finished download stamped complete")
        t.check(!FileManager.default.fileExists(atPath: basket.pendingMarker("m").path), "pending marker removed")
        t.equal(board.status(for: "m"), .ready, "downloaded → Ready")
        t.check(settle { await downloads.fetch("m", into: storage) } == true && storage.fetches == 1,
                "already on disk → no download")

        storage.fail = CocoaError(.fileWriteOutOfSpace)
        storage.partial = true
        t.check(settle { await downloads.fetch("p", into: storage) } == false, "failed download → false")
        if case .failed(let why) = board.status(for: "p") {
            t.check(why.hasPrefix("Download failed:"), "failed download → Failed status")
        } else { t.check(false, "failed download → Failed status", "got \(board.status(for: "p"))") }
        t.check(storage.hasFiles("p") && !downloads.isDownloaded("p", in: storage),
                "an unfinished download's marker beats its partial files")
    }

    // MARK: - Storage completeness (temp dir)

    private static func storage(_ t: inout Checks) {
        let fm = FileManager.default
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let basket = ModelBasket(root: dir.appendingPathComponent("basket"))
        let resources = dir.appendingPathComponent("Resources")
        var custom: [CustomWhisperModel] = []
        var refreshes = 0
        let whisper = WhisperStorage(basket: basket, resources: resources) { refresh in
            if refresh { refreshes += 1 }
            return custom
        }
        func touch(_ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data())
        }

        t.check(!whisper.hasFiles("tiny.en"), "nothing on disk → not downloaded")
        t.check(refreshes == 1, "the check re-reads installed fine-tunes")

        // Legacy rule: every model file + config + tokenizer.
        let folder = whisper.modelsRoot.appendingPathComponent("openai_whisper-tiny.en")
        for name in WhisperStorage.requiredModels {
            touch(folder.appendingPathComponent("\(name).mlmodelc/coremldata.bin"))
        }
        t.check(!whisper.hasFiles("tiny.en"), "model files without config/tokenizer → incomplete")
        try? #"{"vocab_size": 51864, "d_model": 384}"#.write(
            to: folder.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        t.check(!whisper.hasFiles("tiny.en"), "no tokenizer → incomplete")
        touch(basket.root.appendingPathComponent("models/openai/whisper-tiny.en/tokenizer.json"))
        t.check(whisper.hasFiles("tiny.en"), "pre-marker download complete by structure")

        // Marker rule: a stamped folder is complete as-is.
        let turbo = whisper.modelsRoot.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB")
        touch(turbo.appendingPathComponent("AudioEncoder.mlmodelc/coremldata.bin"))
        t.check(!whisper.hasFiles("large-v3-v20240930_626MB"), "partial unstamped folder → incomplete")
        basket.stampComplete(turbo)
        t.check(whisper.hasFiles("large-v3-v20240930_626MB"), "completion marker → complete")
        t.check(!whisper.hasFiles("large-v3"), "large-v3 never borrows turbo's folder")

        whisper.remove("large-v3-v20240930_626MB")
        t.check(!fm.fileExists(atPath: turbo.path) && fm.fileExists(atPath: folder.path),
                "remove deletes only that model's folder")

        // Bundled.
        touch(resources.appendingPathComponent("BundledModels/openai_whisper-base.en/AudioEncoder.mlmodelc"))
        t.check(whisper.hasFiles("base.en") && whisper.bundledFolder("base.en") != nil, "bundled model → available offline")

        // Installed fine-tune.
        let ft = dir.appendingPathComponent("Custom/ft-1")
        for name in WhisperStorage.requiredModels { touch(ft.appendingPathComponent("model/\(name).mlmodelc/x")) }
        touch(ft.appendingPathComponent("tok/models/openai/whisper-small/tokenizer.json"))
        try? #"{"id": "ft-1", "display_name": "Mine", "base_model": "small", "model_folder": "model", "tokenizer_folder": "tok"}"#
            .write(to: ft.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        if let model = CustomWhisperModelRegistry.model(in: ft) { custom = [model] }
        t.check(whisper.hasFiles("ft-1") && whisper.isInstalledLocally("ft-1"), "installed fine-tune → available, local")
        whisper.remove("ft-1")
        t.check(fm.fileExists(atPath: ft.path), "a fine-tune is never deleted by Re-download")
        t.check(!whisper.isInstalledLocally("tiny.en"), "a download isn't a local install")

        // Parakeet: unknown ids are never on disk; the folder is the basket's.
        let parakeet = ParakeetStorage(basket: basket)
        t.check(!parakeet.hasFiles("parakeet-nope") && !parakeet.hasFiles("parakeet-ultra"),
                "Parakeet: nothing provisioned → not downloaded")
        t.check(parakeet.directory(for: .ultra).path.hasPrefix(basket.root.appendingPathComponent("parakeet").path),
                "Parakeet lives under the basket")
    }

    // MARK: - Live input

    private static func live(_ t: inout Checks) {
        let picked = LiveMicInput(capture: MicCapture(), preferred: 7, systemDefault: { 3 })
        let unpicked = LiveMicInput(capture: MicCapture(), preferred: nil, systemDefault: { 3 })
        t.check(picked.device == 7 && unpicked.device == 3, "live mic: the pick, else the system default")
        let routed = DeviceRoutedAudioProcessor(base: AudioProcessor(), mic: picked)
        t.check(routed.preferredDevice == 7, "routed processor takes its mic from the input, not Settings")
    }

    // MARK: - Fakes and helpers

    /// Run `body` on the main actor and spin the main run loop until it
    /// finishes (the self-test runs synchronously on the main thread).
    @discardableResult
    private static func settle<T>(_ seconds: TimeInterval = 10, _ body: @escaping @MainActor () async -> T) -> T? {
        var result: T?
        var done = false
        Task { @MainActor in
            result = await body()
            done = true
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !done, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return result
    }

    private static func plan(interimAfter: Double? = nil,
                             interim: @escaping @MainActor () async -> (any Recognizer)? = { nil },
                             _ load: @escaping @MainActor () async throws -> any Recognizer) -> LoadPlan {
        LoadPlan(firstStage: "Loading", detail: "fake", load: { _ in try await load() },
                 interim: interimAfter.map { LoadPlan.Interim(after: $0, load: interim) },
                 copy: LoadFailureCopy(engine: "Fake", timedOutStatus: "Timed out.",
                                       timedOutReport: "The fake model didn't finish loading.",
                                       failedReport: "The fake model failed to load."))
    }

    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slive-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeWAV(_ samples: [Float], to url: URL) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buffer)
    }
}

private final class Clock {
    private var offset: TimeInterval = 0
    private let start = Date()
    func advance(_ seconds: TimeInterval) { offset += seconds }
    var now: () -> Date { { [unowned self] in self.start.addingTimeInterval(self.offset) } }
}

@MainActor
private final class FakeBoard: ModelStatusBoard {
    var statuses: [String: ModelStatus] = [:]
    func status(for model: String) -> ModelStatus { statuses[model] ?? .notDownloaded }
    func setStatus(_ status: ModelStatus, for model: String) { statuses[model] = status }
}

private final class FaultRecorder {
    var titles: [String] = []
    var sink: FaultSink { FaultSink { [unowned self] _, title, _, _, _, _, _ in self.titles.append(title) } }
}

@MainActor
private struct FakeLoader: ModelLoader {
    let make: (String) -> LoadPlan?
    func plan(_ id: String) -> LoadPlan? { make(id) }
}

@MainActor
private final class FakeRecognizer: Recognizer {
    var text = "text"
    var delay: UInt64 = 0
    var warmUpDelay: UInt64 = 0
    var error: Error?
    var calls = 0
    var warmUps = 0
    var events: [String] = []
    var skipsWarmUpWithoutAudio = false

    func transcribe(_ samples: [Float]) async throws -> String {
        calls += 1
        events.append("decode")
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return text
    }

    func warmUpClip(bundled: [Float]?) -> [Float]? { skipsWarmUpWithoutAudio ? nil : bundled }

    func warmUp(_ audio: [Float]) async throws {
        warmUps += 1
        events.append("warm start")
        if warmUpDelay > 0 { try? await Task.sleep(nanoseconds: warmUpDelay) }
        events.append("warm end")
    }
}

@MainActor
private final class FakeStorage: ModelStorage {
    var files: Set<String> = []
    var fetches = 0
    var fail: Error?
    var partial = false
    var folder: URL?

    func hasFiles(_ id: String) -> Bool { files.contains(id) }
    func isInstalledLocally(_ id: String) -> Bool { false }
    func fetch(_ id: String, progress: DownloadProgress) async throws -> URL? {
        fetches += 1
        progress.report(0.5)
        try await Task.sleep(nanoseconds: 50_000_000)
        if partial { files.insert(id) }
        if let fail { throw fail }
        files.insert(id)
        return folder
    }
    func remove(_ id: String) { files.remove(id) }
}
