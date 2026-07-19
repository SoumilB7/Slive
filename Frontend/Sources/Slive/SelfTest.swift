import AppKit
import CoreGraphics

/// Built-in check suite, run with `Slive --self-test` (or
/// `swift run Slive --self-test`). Prints one line per check and exits 0 only
/// if everything passed.
///
/// Why not XCTest / Swift Testing: this machine builds with the Command Line
/// Tools toolchain, which ships neither. Running assertions inside the real
/// module keeps the exact production code paths under test with zero extra
/// dependencies. Everything here is pure logic — no event posting, no AX, no
/// audio, no files outside the process — so the suite is safe to run headless.
@MainActor
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func runAndExit() -> Never {
        print("Slive self-test\n===============")
        hotkeyModelChecks()
        hotkeyMatchingChecks()
        providerChecks()
        speedTierChecks()
        silenceTrimChecks()
        textHygieneChecks()
        pacingChecks()
        wpmChecks()
        overlayMetricsChecks()
        sampleFormatChecks()
        stitchChecks()
        transcriptDiffChecks()
        print("===============\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - Assertion helpers

    private static func check(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✅ \(name)")
        } else {
            failed += 1
            print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    private static func equal<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        check(a == b, name, "got \(a), expected \(b)")
    }

    // MARK: - Hotkey model

    private static let fn = CGEventFlags.maskSecondaryFn.rawValue
    private static let ctrl = CGEventFlags.maskControl.rawValue
    private static let cmd = CGEventFlags.maskCommand.rawValue
    private static let alt = CGEventFlags.maskAlternate.rawValue

    private static func hotkeyModelChecks() {
        print("[Hotkey model]")
        check(Hotkey.fnDefault.isModifierOnly && Hotkey.fnDefault.isValid, "fn default shape")
        check(!Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /").isModifierOnly, "chord shape")
        check(!Hotkey(modifiers: 0, keyCode: nil, label: "—").isValid, "empty hotkey invalid")

        equal(Hotkey.makeLabel(modifiers: 0, keyChar: nil), "—", "empty label")
        equal(Hotkey.makeLabel(modifiers: cmd, keyChar: nil), "⌘", "cmd label")
        equal(Hotkey.makeLabel(modifiers: ctrl | alt, keyChar: "K"), "⌃⌥ K", "chord label order")

        // Persistence round-trip: a change here breaks saved shortcuts.
        let original = Hotkey(modifiers: fn | ctrl, keyCode: 49, label: "⌃fn Space")
        if let data = try? JSONEncoder().encode(original),
           let back = try? JSONDecoder().decode(Hotkey.self, from: data) {
            equal(back, original, "hotkey codable round-trip")
        } else {
            check(false, "hotkey codable round-trip", "encode/decode threw")
        }

        check(Hotkey.isSpecialKey(53) && Hotkey.isSpecialKey(122) && Hotkey.isSpecialKey(123),
              "Esc/F1/← are special")
        check(!Hotkey.isSpecialKey(0) && !Hotkey.isSpecialKey(49), "'a'/Space are not special")
        equal(Hotkey.keyChar(forKeyCode: 49, characters: nil), "Space", "Space key name")
        equal(Hotkey.keyChar(forKeyCode: 0, characters: "a"), "A", "letter key name")
        equal(Hotkey.keyChar(forKeyCode: 200, characters: ""), "key200", "unknown key name")

        for flag: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn] {
            check(Hotkey.modifierMask & flag.rawValue != 0, "mask covers \(flag.rawValue)")
        }
        check(Hotkey.modifierMask & CGEventFlags.maskAlphaShift.rawValue == 0,
              "mask excludes caps lock")
    }

    // MARK: - Hotkey matching (the real HotkeyMonitor.handle path)

    private static func flagsEvent(_ flags: UInt64, marker: Bool = false) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: flags)
        if marker { e.setIntegerValueField(.eventSourceUserData, value: PasteEngine.syntheticMarker) }
        return e
    }

    /// Fresh monitor with deterministic targets (never start()ed — no tap, no
    /// timers; we drive handle() directly, the same entry real events take).
    private static func makeMonitor(started: @escaping (HotkeyAction) -> Void,
                                    stopped: @escaping (HotkeyAction) -> Void) -> HotkeyMonitor {
        let m = HotkeyMonitor()
        m.hotkey = Hotkey(modifiers: fn, keyCode: nil, label: "fn")
        m.assistantHotkey = nil
        m.streamHotkey = Hotkey(modifiers: ctrl, keyCode: nil, label: "⌃")
        m.onStart = started
        m.onStop = stopped
        return m
    }

    private static func hotkeyMatchingChecks() {
        print("[Hotkey matching]")
        var started: [HotkeyAction] = []
        var stopped: [HotkeyAction] = []
        var m = makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })

        _ = m.handle(type: .flagsChanged, event: flagsEvent(fn))
        equal(started, [.dictate], "exact fn starts dictate")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0))
        equal(stopped, [.dictate], "release stops dictate")

        started = []; stopped = []
        _ = m.handle(type: .flagsChanged, event: flagsEvent(ctrl))
        equal(started, [.stream], "exact ⌃ starts stream")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0))

        // Dominance: both gestures held at once → dictate (highest priority) wins.
        started = []; stopped = []
        _ = m.handle(type: .flagsChanged, event: flagsEvent(fn | ctrl))
        equal(started, [.dictate], "dictate dominates fn+⌃")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0))

        // Exact match beats subset priority: retarget stream to exactly fn+⌃.
        started = []; stopped = []
        m = makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        m.streamHotkey = Hotkey(modifiers: fn | ctrl, keyCode: nil, label: "fn⌃")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(fn | ctrl))
        equal(started, [.stream], "exact fn+⌃ prefers stream over fn-subset")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0))

        // Switching gestures in one transition stops the old, starts the new.
        started = []; stopped = []
        m = makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        _ = m.handle(type: .flagsChanged, event: flagsEvent(fn))
        _ = m.handle(type: .flagsChanged, event: flagsEvent(ctrl))
        equal(started, [.dictate, .stream], "switch starts new action")
        equal(stopped, [.dictate], "switch stops old action")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0))

        // Unrelated modifier does nothing.
        started = []; stopped = []
        m = makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        _ = m.handle(type: .flagsChanged, event: flagsEvent(cmd))
        check(started.isEmpty && stopped.isEmpty, "⌘ alone does nothing")

        // Slive's own tagged keystrokes must never stop an active stream.
        started = []; stopped = []
        m = makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        _ = m.handle(type: .flagsChanged, event: flagsEvent(ctrl))
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0, marker: true))
        check(stopped.isEmpty, "synthetic marker ignored (stream survives own typing)")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0))

        // Chords: the key must be swallowed both ways and drive start/stop.
        started = []; stopped = []
        m = makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        m.hotkey = Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /")
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 44, keyDown: true)!
        down.flags = CGEventFlags(rawValue: alt)
        check(m.handle(type: .keyDown, event: down), "chord key-down swallowed")
        equal(started, [.dictate], "chord starts dictate")
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 44, keyDown: false)!
        up.flags = CGEventFlags(rawValue: alt)
        check(m.handle(type: .keyUp, event: up), "chord key-up swallowed")
        equal(stopped, [.dictate], "chord release stops dictate")

        // A plain letter passes through untouched.
        let plain = CGEvent(keyboardEventSource: nil, virtualKey: 4, keyDown: true)!
        plain.flags = []
        check(!m.handle(type: .keyDown, event: plain), "plain key passes through")

        // macOS synthesizes arrow/Home/End/Page keys as fn+key: their keyDown
        // and keyUp events CARRY maskSecondaryFn without fn ever being
        // touched. They must never read as the fn hotkey (this was the
        // "dictation starts out of nowhere" bug).
        started = []; stopped = []
        m = makeMonitor(started: { started.append($0) }, stopped: { stopped.append($0) })
        let arrowDown = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        arrowDown.flags = CGEventFlags(rawValue: fn)
        check(!m.handle(type: .keyDown, event: arrowDown) && started.isEmpty,
              "fn-flagged arrow key-down cannot phantom-start dictation")
        let arrowUp = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: false)!
        arrowUp.flags = CGEventFlags(rawValue: fn)
        _ = m.handle(type: .keyUp, event: arrowUp)
        check(started.isEmpty && stopped.isEmpty,
              "fn-flagged arrow key-up is equally inert")
        // The real gesture still works after the arrow noise.
        _ = m.handle(type: .flagsChanged, event: flagsEvent(fn))
        equal(started, [.dictate], "real fn flagsChanged still starts dictate")
        _ = m.handle(type: .flagsChanged, event: flagsEvent(0))
        equal(stopped, [.dictate], "and still releases")

        // The stuck-hold watchdog's decision logic: release exactly when the
        // physical state no longer holds every required modifier.
        check(HotkeyMonitor.physicallyReleased(requiredModifiers: fn, physicalFlags: 0),
              "watchdog releases when fn is physically up")
        check(!HotkeyMonitor.physicallyReleased(requiredModifiers: fn, physicalFlags: fn),
              "watchdog holds while fn is physically down")
        check(HotkeyMonitor.physicallyReleased(requiredModifiers: fn | ctrl, physicalFlags: fn),
              "watchdog releases when only part of a combo remains")
        check(!HotkeyMonitor.physicallyReleased(requiredModifiers: fn, physicalFlags: fn | cmd),
              "extra held modifiers don't count as release")
    }

    // MARK: - Provider model (Local runs keyless, on-device)

    private static func providerChecks() {
        print("[Providers]")
        equal(AssistantProvider.local.wire, "local", "local wire value")
        check(!AssistantProvider.local.needsAPIKey && AssistantProvider.local.isLocal,
              "local is keyless and flagged local")
        check(AssistantProvider.allCases.filter { $0 != .local && $0 != .whisper }
                .allSatisfy(\.needsAPIKey),
              "every cloud provider needs a key")
        check(!AssistantProvider.whisper.needsAPIKey
                && !AssistantProvider.assistantChoices.contains(.whisper),
              "whisper is keyless and never an assistant choice")
        check(AssistantProvider.whisper.defaultModel == "large-v3",
              "whisper ground truth defaults to the Accurate judge")
        check(!AssistantProvider.local.needsBaseURL, "local needs no base URL")
        // The floor that separates runnable downloads from config-only repos —
        // shared by the Models page and both model pickers.
        equal(LocalCachedModel.minPickableBytes, 50 * 1_048_576, "local pickable size floor")
        var config = AssistantConfig.default
        config.provider = .local
        equal(config.model(for: .local), "", "local has no default model — must be picked")
        config.setModel("google/gemma-3n-E2B-it", for: .local)
        equal(config.model(for: .local), "google/gemma-3n-E2B-it", "local model override sticks")
    }

    // MARK: - Speed tiers (the latency ⇄ resources contract)

    private static func speedTierChecks() {
        print("[Speed tiers]")
        check(SpeedTier.instant.pinsModels && SpeedTier.instant.primesOnHold
                && SpeedTier.instant.holdsLatencyAssertion && SpeedTier.instant.warmsAfterLoad,
              "Instant spends everything for speed")
        check(!SpeedTier.feather.pinsModels && SpeedTier.feather.idleUnloadAfter != nil
                && !SpeedTier.feather.warmsAfterLoad && !SpeedTier.feather.primesOnHold,
              "Feather spends nothing while idle")
        check(SpeedTier.snappy.pinsModels && !SpeedTier.snappy.primesOnHold
                && SpeedTier.snappy.holdsLatencyAssertion,
              "Snappy keeps models and clocks, drops per-hold priming")

        let factor = SpeedTier.decodeFactor(for: "large-v3-v20240930_626MB")
        let latencies = SpeedTier.allCases.map { $0.estimatedLatency(modelFactor: factor) }
        check(latencies == latencies.sorted() && Set(latencies).count == latencies.count,
              "tier latencies strictly increase Instant → Feather")
        let energies = SpeedTier.allCases.map(\.energyIndex)
        check(energies == energies.sorted(by: >) && Set(energies).count == energies.count,
              "tier energy strictly decreases Instant → Feather")
        // Battery drain: real numbers, checked as numbers.
        let drains = SpeedTier.allCases.map(\.drainMWhPerHour)
        check(drains == drains.sorted(by: >) && Set(drains).count == drains.count,
              "tier battery drain (mWh/hr) strictly decreases Instant → Feather")
        check(SpeedTier.feather.drainMWhPerHour == 0,
              "Feather drains nothing above baseline")
        // Instant = 80 mW idle + 3.5 J × 30/hr ÷ 3.6 = 109.2 mWh/hr.
        check(abs(SpeedTier.instant.drainMWhPerHour - 109.2) < 0.3,
              "Instant drain math: 80 mW + 3.5 J × 30/3.6 ≈ 109 mWh/hr")
        // On a 53 Wh Air battery that is ≈0.206 %/hr.
        if let pct = SpeedTier.instant.drainPercentPerHour(batteryWh: 53) {
            check(abs(pct - 0.206) < 0.01, "percent math: 109 mWh over 53 Wh ≈ 0.21%/hr")
        } else {
            check(false, "percent math returned nil for a real battery")
        }
        check(SpeedTier.instant.drainPercentPerHour(batteryWh: nil) == nil,
              "no battery (desktop) → no percent claim")
        check(SpeedTier.instant.batteryIndex == 1,
              "chart battery fraction tops out at Instant")
        // Receipts quote units, not adjectives.
        let withBattery = SpeedTier.instant.costLines(modelResidentGB: 1.2, batteryWh: 53)
        check(withBattery.first { $0.0 == "Battery" }?.1.contains("%/hr") == true,
              "battery receipt quotes %/hr on machines with a battery")
        let noBattery = SpeedTier.snappy.costLines(modelResidentGB: 1.2, batteryWh: nil)
        check(noBattery.first { $0.0 == "Battery" }?.1.contains("mWh") == true,
              "battery receipt falls back to mWh on wall-powered Macs")
        check(SpeedTier.allCases.allSatisfy { tier in
            tier.costLines(modelResidentGB: 1.2, batteryWh: 53).contains { $0.0 == "Battery" }
        }, "every tier's receipt itemizes battery")
        // The machine checker's battery read, when present, must be sane
        // laptop territory (guards the mAh-vs-percent IOKit trap).
        check(MachineProfile.batteryWh.map { $0 > 20 && $0 < 120 } ?? true,
              "measured battery capacity is in sane laptop range",
              "got \(String(describing: MachineProfile.batteryWh))")
        check(SpeedTier.feather.estimatedRamGB(modelResidentGB: 1.2) < 0.1,
              "Feather's idle RAM is near zero")

        let xs = LatencyGraphView.xPositions(latencies: latencies, width: 400)
        check(xs == xs.sorted() && xs.first! >= 0 && xs.last! <= 400,
              "graph x-positions are ordered and inside the plot")
        check(LatencyGraphView.ms(0.34) == "~340ms" && LatencyGraphView.ms(1.2) == "~1.2s",
              "latency labels format ms under 1s, seconds above")

        // Calibration: measured typical-decode seconds override the guess.
        let measured = SpeedTier.effectiveFactor(measuredTypicalDecode: 0.62, model: "large-v3")
        check(measured.measured && measured.factor == 0.62,
              "measured decode seconds drive the graph directly (no scaling)")
        let fallback = SpeedTier.effectiveFactor(measuredTypicalDecode: nil, model: "large-v3")
        check(!fallback.measured && fallback.factor == SpeedTier.decodeFactor(for: "large-v3"),
              "no calibration falls back to the family estimate")
        let poisoned = SpeedTier.effectiveFactor(measuredTypicalDecode: 45, model: "large-v3")
        check(poisoned.factor <= 10,
              "a poisoned calibration value can never put absurd numbers on the axis")
        check(TranscriptionModel.blendedRate(old: nil, new: 0.2) == 0.2
                && abs(TranscriptionModel.blendedRate(old: 0.2, new: 0.4) - 0.26) < 0.0001,
              "decode-rate EMA seeds on first sample, blends 70/30 after")
        check(!TranscriptionModel.acceptableCalibrationClip(1.0)
                && TranscriptionModel.acceptableCalibrationClip(8)
                && !TranscriptionModel.acceptableCalibrationClip(45),
              "calibration only trusts one-window, dictation-sized clips (3–30s)")

        // The machine checker behind the "maximum reach" tag.
        check(MachineProfile.ramGB > 0, "machine checker reads physical RAM")
        check(MachineProfile.summary.contains("GB") && !MachineProfile.chip.isEmpty,
              "machine summary names the chip and RAM")
    }

    // MARK: - Silence trim (pre-decode)

    private static func silenceTrimChecks() {
        print("[Silence trim]")
        let rate = 16_000
        let quiet = [Float](repeating: 0.001, count: rate)          // 1s near-silence
        let voice = [Float](repeating: 0.1, count: rate / 2)        // 0.5s clear voice

        check(TranscriptionModel.trimSilence(quiet).isEmpty,
              "pure silence trims to empty (skip decode entirely)")

        let padded = quiet + voice + quiet
        let trimmed = TranscriptionModel.trimSilence(padded)
        let padSamples = 2_400
        check(!trimmed.isEmpty
                && trimmed.count >= voice.count
                && trimmed.count <= voice.count + 2 * padSamples + 320,
              "silence-padded voice trims to the voiced span + ~150ms pads",
              "got \(trimmed.count) samples for \(voice.count) voiced")
        // The voiced span itself must survive intact.
        check(trimmed.contains(0.1), "voiced samples survive the trim")

        let bare = TranscriptionModel.trimSilence(voice)
        check(bare.count == voice.count, "no-silence input passes through whole")

        check(TranscriptionModel.trimSilence([Float](repeating: 0, count: 100)).isEmpty,
              "sub-frame input trims to empty")
    }

    // MARK: - Text hygiene

    private static func textHygieneChecks() {
        print("[Text hygiene]")
        equal(TranscriptionModel.cleanStreamText(
                "<|startoftranscript|><|en|><|transcribe|><|0.00|> hello world<|endoftext|>"),
              " hello world", "control tokens stripped")
        equal(TranscriptionModel.cleanStreamText("Waiting for speech..."), "", "placeholder stripped")
        equal(TranscriptionModel.cleanStreamText("just words"), "just words", "plain text untouched")

        equal(ContinuousDictation.normalize("  hello there"), "hello there", "leading spaces stripped")
        equal(ContinuousDictation.normalize("<|en|>hi"), "hi", "normalize strips tokens")
        equal(ContinuousDictation.normalize("Waiting for speech... hi"), "hi", "normalize strips placeholder")
        equal(ContinuousDictation.normalize("a  b"), "a  b", "inner spacing kept")
    }

    // MARK: - Typing pacing

    private static func pacingChecks() {
        print("[Typing pacing]")
        var ceilingOK = true, floorOK = true
        for cps in [12.0, 30.0, 60.0, 119.0] {
            for remaining in [1, 2, 5, 50, 500] {
                let d = LiveTypist.forwardDelay(remaining: remaining, cps: cps)
                if d > 0.10 { ceilingOK = false }
                if d < 1.0 / cps - 1e-9 { floorOK = false }
            }
        }
        check(ceilingOK, "delay never exceeds 100ms ceiling")
        check(floorOK, "delay never types faster than configured cps")
        check(LiveTypist.forwardDelay(remaining: 2, cps: 30)
                >= LiveTypist.forwardDelay(remaining: 100, cps: 30),
              "bigger backlog never slows typing")
    }

    // MARK: - WPM math

    private static func wpmChecks() {
        print("[WPM math]")
        let text30 = Array(repeating: "word", count: 30).joined(separator: " ")
        if let w = SpeakingStats.wpm(text: text30, seconds: 12) {
            check(abs(w - 150) < 0.001, "30 words / 12s = 150 WPM", "got \(w)")
        } else {
            check(false, "30 words / 12s = 150 WPM", "returned nil")
        }
        check(SpeakingStats.wpm(text: "", seconds: 5) == nil, "no words rejected")
        check(SpeakingStats.wpm(text: "   ", seconds: 5) == nil, "whitespace-only rejected")
        check(SpeakingStats.wpm(text: "hi", seconds: 0.3) == nil, "sub-0.5s rejected")
        let burst = Array(repeating: "w", count: 100).joined(separator: " ")
        check(SpeakingStats.wpm(text: burst, seconds: 1) == nil, "6000 WPM rejected as implausible")
        if let w = SpeakingStats.wpm(text: "a b\tc\nd", seconds: 60) {
            check(abs(w - 4) < 0.001, "words split on any whitespace", "got \(w)")
        } else {
            check(false, "words split on any whitespace", "returned nil")
        }
    }

    // MARK: - Overlay geometry

    private static func overlayMetricsChecks() {
        print("[Overlay geometry]")
        let short = OverlayMetrics.panelSize(for: "hi")
        let long = OverlayMetrics.panelSize(
            for: String(repeating: "a fairly long sentence about nothing. ", count: 8))
        check(long.height > short.height, "panel grows with text")
        check(long.width >= short.width, "panel width never shrinks with more text")

        var boundsOK = true
        for text in ["", "x", String(repeating: "word ", count: 500)] {
            let p = OverlayMetrics.panelSize(for: text)
            if p.width <= 0 || p.height <= 0 || p.height >= 2000 { boundsOK = false }
        }
        check(boundsOK, "panel sizes positive and bounded")

        let base = OverlayMetrics.panelSize(for: "answer")
        let assistant = OverlayMetrics.assistantPanelSize(for: "answer")
        check(assistant.height == base.height + OverlayMetrics.continueFooterHeight
                && assistant.width == base.width,
              "assistant panel adds exactly the Continue footer")
        check(OverlayMetrics.assistantStreamingPanelSize.height
                == OverlayMetrics.streamingPanelSize.height + OverlayMetrics.continueFooterHeight,
              "streaming assistant panel adds exactly the Continue footer")
    }

    // MARK: - Training sample format

    private static func sampleFormatChecks() {
        print("[Sample format]")
        // The on-disk JSONL format must round-trip with ISO-8601 dates — a
        // change here silently orphans every previously captured sample.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sample = EditSample(
            id: "abc", createdAt: Date(timeIntervalSince1970: 1_752_700_000),
            app: "com.example.app", transcript: "hello world", finalText: "",
            edited: false, confidence: "audio", audioFile: "audio/abc.wav")
        if let data = try? encoder.encode(sample),
           let back = try? decoder.decode(EditSample.self, from: data) {
            check(back.id == sample.id && back.transcript == sample.transcript
                    && back.audioFile == sample.audioFile
                    && abs(back.createdAt.timeIntervalSince1970
                           - sample.createdAt.timeIntervalSince1970) < 1.0,
                  "sample round-trips with ISO dates")
        } else {
            check(false, "sample round-trips with ISO dates", "encode/decode threw")
        }

        // Legacy lines (edit-tracking era, no llm fields) must still decode.
        let legacy = """
        {"id":"x","createdAt":"2026-07-16T10:00:00Z","app":"com.a.b","transcript":"t",\
        "finalText":"t2","edited":true,"confidence":"high","audioFile":null}
        """
        if let s = try? decoder.decode(EditSample.self, from: legacy.data(using: .utf8)!) {
            check(s.edited && s.finalText == "t2" && s.audioFile == nil
                    && s.llmTranscript == nil && s.llmModel == nil,
                  "legacy sample decodes (llm fields nil)")
        } else {
            check(false, "legacy sample decodes (llm fields nil)", "decode threw")
        }

        // Ground-truth fields must round-trip.
        var withLLM = sample
        withLLM.llmTranscript = "hello world."
        withLLM.llmModel = "gemini-2.5-flash"
        if let data = try? encoder.encode(withLLM),
           let back = try? decoder.decode(EditSample.self, from: data) {
            check(back.llmTranscript == "hello world." && back.llmModel == "gemini-2.5-flash",
                  "ground-truth fields round-trip")
        } else {
            check(false, "ground-truth fields round-trip", "encode/decode threw")
        }
    }

    // MARK: - Transcript word-diff (Training table highlighting)

    private static func transcriptDiffChecks() {
        print("[TranscriptDiff — word-level LCS]")

        let equal = TranscriptDiff.matchMask(
            output: ["the", "same", "words"], truth: ["the", "same", "words"])
        check(equal == [true, true, true], "equal strings match fully")

        let insert = TranscriptDiff.matchMask(
            output: ["the", "model", "loads"],
            truth: ["the", "whisper", "model", "loads"])
        check(insert == [true, false, true, true], "insertion marks only the new word")

        let replace = TranscriptDiff.matchMask(
            output: ["whisper", "kit", "engine"],
            truth: ["WhisperKit", "engine"])
        check(replace == [false, true], "replacement (incl. case change) marks the corrected word")

        // Deletion (output had an extra word the truth dropped): every truth
        // word is on the LCS, so there's no word to recolor — instead the
        // word at the deletion site gets an underline, and the text stays
        // verbatim (one small mark, not a whole orange paragraph).
        let deletion = TranscriptDiff.diff(
            output: ["the", "the", "cat"], truth: ["the", "cat"])
        check(deletion.mask == [true, true], "deletion case matches every truth word")
        check(!deletion.deletionSites.isEmpty, "deletion case reports its site")
        let deletionStyled = TranscriptDiff.attributed(
            output: "the the cat", truth: "the cat", base: .white, changed: .orange)
        check(deletionStyled != nil, "deletion-only correction renders a real diff")
        if let deletionStyled {
            check(String(deletionStyled.characters) == "the cat",
                  "deletion rendering keeps the truth text verbatim")
            check(deletionStyled.runs.contains { $0.underlineStyle != nil },
                  "deletion site is underlined")
        }
        // The screenshot case: "explain to me" → "explain me" must underline
        // one word, not orange the sentence.
        let dropTo = TranscriptDiff.attributed(
            output: "can you explain to me the flow",
            truth: "can you explain me the flow", base: .white, changed: .orange)
        check(dropTo != nil
                && dropTo.map { String($0.characters) } == "can you explain me the flow"
                && dropTo!.runs.contains { $0.underlineStyle != nil },
              "a single dropped word underlines its neighbor only")

        let emptyOut = TranscriptDiff.matchMask(output: [], truth: ["a", "b"])
        check(emptyOut == [false, false], "empty output marks all truth words changed")

        let short = TranscriptDiff.attributed(
            output: "hello there world", truth: "hello brave world",
            base: .white, changed: .orange)
        check(short != nil, "short strings produce an attributed diff")
        if let short {
            check(String(short.characters) == "hello brave world",
                  "attributed diff preserves the truth text verbatim")
        }

        let longWords = Array(repeating: "w", count: TranscriptDiff.maxWords + 1)
            .joined(separator: " ")
        let over = TranscriptDiff.attributed(
            output: "short", truth: longWords, base: .white, changed: .orange)
        check(over == nil, "over-length input falls back to whole-string styling (nil)")

        // Divergence — the "way off" flag's measure (flag fires above 0.5).
        // (Plain `check` here: a local mask named `equal` shadows the helper.)
        check(TranscriptDiff.divergence(output: "a b c d", truth: "a b c d") == 0,
              "identical strings diverge 0")
        check(TranscriptDiff.divergence(output: "a b c d", truth: "w x y z") == 1,
              "disjoint strings diverge 1")
        check(TranscriptDiff.divergence(output: "a b c d", truth: "a b y z") == 0.5,
              "half-changed diverges exactly 0.5 — at the flag boundary, not past it")
        check(TranscriptDiff.divergence(output: "a b c d", truth: "a x y z") > 0.5,
              "three-quarters-changed crosses the way-off boundary")
        check(TranscriptDiff.divergence(output: "", truth: "anything at all") == 1,
              "empty output vs text diverges 1")

        // A realistic long dictation (300 words, one corrected) must produce a
        // real word-diff — the old 200-word cap painted such rows all-orange.
        var longOut = (0..<300).map { "word\($0)" }
        var longTru = longOut
        longTru[150] = "corrected"
        let longMask = TranscriptDiff.matchMask(output: longOut, truth: longTru)
        check(longMask.filter { !$0 }.count == 1 && longMask[150] == false,
              "300-word diff marks exactly the one corrected word")
        longOut = []; longTru = []
    }

    // MARK: - Stitched release (seam merger)

    private static func stitchChecks() {
        print("[Stitch seam]")
        // Exact duplicated words at the seam are dropped.
        equal(ContinuousDictation.stitchTranscripts(
                confirmed: "the quarterly report", tail: "quarterly report is due Friday"),
              "the quarterly report is due Friday", "seam dedup")
        // Case + punctuation differences still match; confirmed rendering wins.
        equal(ContinuousDictation.stitchTranscripts(
                confirmed: "we shipped it. The Report,", tail: "the report is late"),
              "we shipped it. The Report, is late", "case/punct-insensitive seam")
        // No overlap → plain join, nothing dropped.
        equal(ContinuousDictation.stitchTranscripts(
                confirmed: "hello world", tail: "goodbye moon"),
              "hello world goodbye moon", "no-overlap join")
        // Empty sides pass through.
        equal(ContinuousDictation.stitchTranscripts(confirmed: "", tail: "only tail"),
              "only tail", "empty confirmed")
        equal(ContinuousDictation.stitchTranscripts(confirmed: "only confirmed", tail: ""),
              "only confirmed", "empty tail")
        // Longest overlap wins over a shorter accidental one.
        equal(ContinuousDictation.stitchTranscripts(
                confirmed: "so so it goes", tail: "so it goes on and on"),
              "so so it goes on and on", "longest overlap preferred")
        // A repeated-phrase tail isn't over-trimmed (only the seam overlap goes).
        equal(ContinuousDictation.stitchTranscripts(
                confirmed: "again and again", tail: "and again and again we tried"),
              "again and again and again we tried", "repeat phrase not over-trimmed")
    }
}
