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

        // Deletion (output hallucinated an extra word): every truth word is on
        // the LCS, so truth-side coloring has nothing to mark — attributed()
        // must fall back to whole-string styling, not render all-white.
        let deletion = TranscriptDiff.matchMask(
            output: ["the", "the", "cat"], truth: ["the", "cat"])
        check(deletion == [true, true], "deletion case matches every truth word")
        let deletionStyled = TranscriptDiff.attributed(
            output: "the the cat", truth: "the cat", base: .white, changed: .orange)
        check(deletionStyled == nil,
              "deletion-only correction falls back to whole-string styling (nil)")

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
