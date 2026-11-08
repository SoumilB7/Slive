import Combine
import Foundation
import SliveTestKit

private let ctrl = Fixtures.ctrl
private let alt = Fixtures.alt
private let cmd = Fixtures.cmd

/// Every option a person can set × every value it can hold × every form an
/// older or newer build or a hand-edited plist can leave behind. The Nov 13
/// freeze came from a value nobody on the team used; this walks all of them.
///
/// Completeness is enforced, not remembered: `options` must name exactly the
/// keys `Settings` declares (Mirror over every `@Stored` + every `ActionSpec`
/// slot and switch), and `options` + `otherKeys` exactly the keys the app's
/// sources persist (a scan of every file that touches UserDefaults /
/// `@AppStorage` / `KeyValueStore`). A new key fails here until it's listed
/// with its values.
@MainActor
enum SettingsOptionsTests {
    static let suite = TestSuite(name: "Settings options") { t in
        print("[Settings options]")
        // Settings.init and verboseLogging drive the log gate; keep the real one.
        let savedLogGate = Log.enabled
        defer { Log.enabled = savedLogGate }

        inventory(&t)
        sourceScan(&t)
        for option in options { option.run(&t) }
        freshInstall(&t)
        migrations(&t)
        sameValueWrites(&t)
    }

    // MARK: - The inventory

    /// One user-facing option: its key, how to print its value (snapshots),
    /// and its checks.
    struct Option {
        let key: String
        let show: (Settings) -> String
        let run: (inout Checks) -> Void
    }

    static let options: [Option] = [
        // Shortcuts and their switches (ActionSpec).
        slot(.dictation), slot(.dictationToggle), slot(.assistant), slot(.stream), slot(.streamToggle),
        toggle(.dictation), toggle(.dictationToggle), toggle(.stream), toggle(.streamToggle),
        // General.
        flag("autoInsert", \.autoInsert),
        text("hotwords", \.hotwords),
        text("contextPrompt", \.contextPrompt),
        slider("holdActivationDelay", \.holdActivationDelay, Settings.holdDelayRange, default: 0),
        slider("overlayOpacity", \.overlayOpacity, Settings.overlayOpacityRange, default: 0.4),
        flag("pillOnRight", \.pillOnRight),
        speedTier(),
        // Speech models.
        model("whisperModel", \.whisperModel, use: .dictation, default: ModelCatalog.defaultDictation,
              emits: .dictationModel),
        model("continuousModel", \.continuousModel, use: .continuous, default: ModelCatalog.defaultContinuous,
              emits: .continuousModel),
        slider("continuousTypeCPS", \.continuousTypeCPS, Settings.typeCPSRange, default: 80),
        // Audio.
        flag("echoCancellation", \.echoCancellation),
        text("inputDeviceUID", \.inputDeviceUID, extra: ["BuiltInMicrophoneDevice", "00-1B-66-AA-BB-CC:input"]),
        text("inputDeviceName", \.inputDeviceName, extra: ["MacBook Pro Microphone", "HP H250"]),
        // Assistant + local inference.
        assistantConfig(),
        flag("localQuantized", \.localQuantized),
        slider("localMemLimitGB", \.localMemLimitGB,
               Settings.localMemMinGB...Settings.localMemMaxGB(ramGB: MachineProfile.ramGB),
               default: Settings.localMemDefaultGB(ramGB: MachineProfile.ramGB)),
        // Data / labels.
        flag("captureEdits", \.captureEdits),
        slider("captureMaxGB", \.captureMaxGB, Settings.captureMaxGBRange, default: 2),
        choice("groundTruthProvider", \.groundTruthProvider, AssistantProvider.allCases, default: .openai),
        groundTruthModel(),
        text("groundTruthBaseURL", \.groundTruthBaseURL,
             extra: ["https://openrouter.ai/api/v1", "http://localhost:11434/v1", "not a url"]),
        text("groundTruthPrompt", \.groundTruthPrompt),
        text("consensusPrompt", \.consensusPrompt),
        choice("groundTruthRecipe", \.groundTruthRecipe, GroundTruthRecipe.allCases, default: .consensusFormat,
               alsoWrites: [Settings.customFourMigrationKey],
               migrates: { $0 == .consensus ? .consensusFormat : $0 }),   // the Custom 4 move
        flag("autoLabelNew", \.autoLabelNew),
        // Diagnostics.
        flag("verboseLogging", \.verboseLogging),
        flag("reportProblems", \.reportProblems),
    ]

    /// Persisted, but not an option: app state, one-off UI flags, AppKit's.
    static let otherKeys: [String: String] = [
        "didFirstRun": "first-run flag (Settings)",
        Settings.customFourMigrationKey: "Custom 4 migration marker (Settings)",
        "balancedSuggestionDismissed": "@AppStorage, BalancedSuggestion card",
        "liveTypingSuggestionDismissed": "@AppStorage, LiveTypingSuggestionCard",
        "wpm.last": "SpeakingStats", "wpm.average": "SpeakingStats",
        "wpm.best": "SpeakingStats", "wpm.count": "SpeakingStats",
        "typicalDecodeSeconds": "DecodeMetricsStore",
        "SliveSettings": "Settings window autosave name (AppKit)",
        "NSWindow Frame \\(autosaveName)": "AppKit's autosaved Settings frame (read only)",
    ]

    /// Every file allowed to persist. A new one must add its keys above.
    static let persistingFiles: Set<String> = [
        "Slive/Settings/Model/Settings.swift",
        "Slive/Settings/Model/SettingsStore.swift",
        "Slive/Hotkey/HotkeyAction.swift",
        "Slive/Settings/Components/ModelPicker.swift",
        "Slive/Settings/General/LiveTypingSuggestionCard.swift",
        "Slive/Settings/SettingsWindow.swift",
        "Slive/History/SpeakingStats.swift",
        "Slive/Transcription/Decode/DecodeMetricsStore.swift",
    ]

    // Not in the store, so not here: launch at login (SMAppService), API keys
    // and the HF token (Keychain, CredentialStore), the edition (Info.plist
    // SliveEdition), and dev env vars (SLIVE_DEBUG, FLOWY_PROMPTS_DIR,
    // FLOWY_BACKEND_DIR, SLIVE_CPU_COPY_AFTER, SLIVE_TEST_ANE_HANG).

    private static func inventory(_ t: inout Checks) {
        let s = make(InMemoryStore())
        let declared = s.storedSettings.map(\.key)
            + ActionSpec.all.flatMap(\.slots).compactMap(\.spec).flatMap { [$0.key] + [$0.switchKey].compactMap { $0 } }
        let listed = options.map(\.key)
        t.equal(Set(listed).count, listed.count, "inventory: every option listed once")
        t.equal(Set(declared).count, declared.count, "inventory: no key declared twice")
        let missing = Set(declared).subtracting(listed).sorted()
        let stale = Set(listed).subtracting(declared).sorted()
        t.check(missing.isEmpty && stale.isEmpty,
                "inventory: \(listed.count) options = every @Stored + shortcut + switch key",
                "add to SettingsOptionsTests.options: \(missing); no longer declared: \(stale)")
    }

    // MARK: - Source scan

    /// The Sources folder this binary was built from.
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)   // …/Sources/Slive/SelfTest/Suites/<this>.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Key literals in persisting code: `@AppStorage("k")`, `@Stored("k"`,
    /// `key:` / `forKey:` / `switchKey:` / `modelKey: "k"`, `static let x = "k"`.
    private static let keyPatterns = [
        #"@AppStorage\("([^"]*)""#,
        #"@Stored\("([^"]*)""#,
        #"\b[A-Za-z]*[kK]ey: "([^"]*)""#,
        #"static let \w+ = "([^"]*)""#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let persistsPattern = try! NSRegularExpression(
        pattern: #"UserDefaults|@AppStorage|KeyValueStore|CFPreferences"#)

    private static func sourceScan(_ t: inout Checks) {
        let root = sourcesRoot
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("Slive/Settings/Model/Settings.swift").path),
              let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            t.check(false, "source scan: source tree found", "no Sources at \(root.path)")
            return
        }
        var files: Set<String> = []
        var keys: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            guard !rel.contains("/SelfTest/"), !rel.hasPrefix("SliveCoreSuites/"),
                  !rel.hasPrefix("SliveTestKit/"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let all = NSRange(code.startIndex..., in: code)
            guard persistsPattern.firstMatch(in: code, range: all) != nil else { continue }
            files.insert(rel)
            for pattern in keyPatterns {
                for match in pattern.matches(in: code, range: all) {
                    if let r = Range(match.range(at: 1), in: code) { keys.insert(String(code[r])) }
                }
            }
        }
        t.check(files == persistingFiles, "source scan: \(files.count) files persist settings, all known",
                "new: \(files.subtracting(persistingFiles).sorted()); gone: \(persistingFiles.subtracting(files).sorted())")
        let known = Set(options.map(\.key)).union(otherKeys.keys)
        // Keys declared through constants (ActionSpec, Settings' Setting
        // statics) are found as literals; every literal must be known.
        t.check(keys.subtracting(known).isEmpty,
                "source scan: every persisted key literal is in the inventory",
                "unlisted: \(keys.subtracting(known).sorted())")
        t.check(Set(otherKeys.keys).isSubset(of: keys),
                "source scan: every non-option key still exists",
                "gone: \(Set(otherKeys.keys).subtracting(keys).sorted())")
        let prompts = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Backend/prompts/\(AssistantConfig.default.promptName).md")
        t.check(fm.fileExists(atPath: prompts.path),
                "default assistant prompt '\(AssistantConfig.default.promptName)' ships in Backend/prompts")
    }

    // MARK: - Option builders

    /// Writes every value through a fresh Settings over one store, then
    /// checks: the value reads back live and in a new Settings, a real
    /// change sends exactly one event (`emits`) and one objectWillChange,
    /// the value it already holds sends none and writes nothing (`@Stored`
    /// drops same-value writes: a view body writing one looped forever), and
    /// nothing else moved: no other key written, every other option still at
    /// its default. `dedupes: false` is for the shortcut and switch setters,
    /// which aren't `@Stored` and still publish every write.
    private static func exercise<V: Equatable>(
        _ key: String, values: [V], emits: SettingsChange?, alsoWrites: Set<String> = [],
        dedupes: Bool = true,
        read: @escaping (Settings) -> V, write: @escaping (Settings, V) -> Void,
        _ t: inout Checks
    ) {
        var persisted: [String] = []
        var events: [String] = []
        var leaks: [String] = []
        for value in values {
            let store = InMemoryStore()
            let s = make(store)
            let before = snapshot(s)
            var got: [SettingsChange] = []
            var wills = 0
            var bag: Set<AnyCancellable> = []
            s.changes.sink { got.append($0) }.store(in: &bag)
            s.objectWillChange.sink { wills += 1 }.store(in: &bag)

            let changes = !dedupes || read(s) != value
            write(s, value)
            let fresh = make(store)
            if read(s) != value || read(fresh) != value {
                persisted.append("\(value) → live \(read(s)), fresh \(read(fresh))")
            }
            let one = changes ? emits.map { [$0] } ?? [] : []
            let will = changes ? 1 : 0
            if got != one || wills != will { events.append("\(value): \(got), \(wills) will-change") }
            if !changes, store.values[key] != nil { events.append("\(value): the same value was written") }
            write(s, value)
            if got != (dedupes ? one : one + one) || wills != (dedupes ? will : 2) {
                events.append("\(value) again: \(got), \(wills) will-change")
            }

            let stray = Set(store.values.keys).subtracting([key]).subtracting(alsoWrites)
            let after = snapshot(fresh)
            let moved = before.keys.filter { $0 != key && before[$0] != after[$0] }
            if !stray.isEmpty || !moved.isEmpty { leaks.append("\(value): wrote \(stray.sorted()), moved \(moved.sorted())") }
        }
        t.check(persisted.isEmpty, "\(key): \(values.count) values persist and read back", "\(persisted)")
        let rule = dedupes ? "per real change, none for the same value" : "per write"
        t.check(events.isEmpty, "\(key): \(emits.map { "one \($0) event" } ?? "no event") + one will-change \(rule)",
                "\(events)")
        t.check(leaks.isEmpty, "\(key): a write touches only its own key and option", "\(leaks)")
    }

    /// Stored forms (hostile, legacy, foreign) → the value each must load as.
    /// Every option also gets `junk`: types no setting is stored as.
    private static func loads<V: Equatable>(
        _ key: String, _ forms: [(stored: Any, reads: V)], default value: V,
        read: @escaping (Settings) -> V, _ t: inout Checks
    ) {
        let junk: [Any] = [[1, 2, 3], ["k": "v"], Date(timeIntervalSince1970: 0)]
        let all = forms + junk.map { ($0, value) }
        var wrong: [String] = []
        for (stored, expected) in all {
            let got = read(make(InMemoryStore([key: stored])))
            if got != expected { wrong.append("\(stored) → \(got), expected \(expected)") }
        }
        t.check(wrong.isEmpty, "\(key): \(all.count) stored forms load safely to the right value", "\(wrong)")
    }

    private static func flag(_ key: String, _ path: ReferenceWritableKeyPath<Settings, Bool>) -> Option {
        Option(key: key, show: { "\($0[keyPath: path])" }) { t in
            let read = { (s: Settings) in s[keyPath: path] }
            exercise(key, values: [true, false, true], emits: nil, read: read,
                     write: { $0[keyPath: path] = $1 }, &t)
            let d = read(make(InMemoryStore()))
            loads(key, [(true, true), (false, false), (1, true), (0, false), (2.5, true),
                        ("YES", true), ("no", false), ("true", true), ("FALSE", false), ("1", true), ("0", false),
                        ("garbage", d), ("", d), (Data([0xFF]), d)],
                  default: d, read: read, &t)
        }
    }

    private static func text(_ key: String, _ path: ReferenceWritableKeyPath<Settings, String>,
                             extra: [String] = []) -> Option {
        Option(key: key, show: { $0[keyPath: path] }) { t in
            let read = { (s: Settings) in s[keyPath: path] }
            let values = ["", "Slive, Kore, WhisperKit", "naïve café — 日本語 🎙️", "line one\nline two\n",
                          "  padded  ", String(repeating: "long ", count: 4_000)] + extra
            exercise(key, values: values, emits: nil, read: read, write: { $0[keyPath: path] = $1 }, &t)
            loads(key, [("kept", "kept"), (5, ""), (true, ""), (Data("x".utf8), "")],
                  default: "", read: read, &t)
        }
    }

    private static func slider(_ key: String, _ path: ReferenceWritableKeyPath<Settings, Double>,
                               _ range: ClosedRange<Double>, default d: Double) -> Option {
        Option(key: key, show: { "\($0[keyPath: path])" }) { t in
            let read = { (s: Settings) in s[keyPath: path] }
            let lo = range.lowerBound, hi = range.upperBound, mid = (lo + hi) / 2
            let whole = Int(mid)   // `defaults write -int`
            t.check(range.contains(d), "\(key): default \(d) inside the slider's \(lo)…\(hi)")
            exercise(key, values: [lo, d, mid, hi], emits: nil, read: read,
                     write: { $0[keyPath: path] = $1 }, &t)
            loads(key, [(lo, lo), (hi, hi), (mid, mid), (lo - 1, lo), (hi + 1, hi), (-1e300, lo), (1e300, hi),
                        (Double.nan, d), (Double.infinity, d), (-Double.infinity, d),
                        ("\(mid)", mid), (" \(hi) ", hi), ("garbage", d), ("", d), ("nan", d), ("inf", d),
                        (Data([0x01]), d), (whole, min(max(Double(whole), lo), hi))],
                  default: d, read: read, &t)
            // Out-of-range writes (scripts, a future slider) read back clamped.
            let store = InMemoryStore()
            make(store)[keyPath: path] = hi * 1000 + 1
            t.equal(read(make(store)), hi, "\(key): a write past the range reads back clamped")
        }
    }

    private static func choice<E: RawRepresentable & Equatable>(
        _ key: String, _ path: ReferenceWritableKeyPath<Settings, E>, _ cases: [E], default d: E,
        alsoWrites: Set<String> = [], migrates: @escaping (E) -> E = { $0 }
    ) -> Option where E.RawValue == String {
        Option(key: key, show: { $0[keyPath: path].rawValue }) { t in
            let read = { (s: Settings) in s[keyPath: path] }
            exercise(key, values: cases + [d], emits: nil, alsoWrites: alsoWrites, read: read,
                     write: { $0[keyPath: path] = $1 }, &t)
            var forms: [(stored: Any, reads: E)] = cases.map { ($0.rawValue, migrates($0)) }
            forms += [("removed-case", d), ("", d), (d.rawValue.uppercased(), d), (" \(d.rawValue)", d),
                      (3, d), (true, d), (Data(d.rawValue.utf8), d)]
            loads(key, forms, default: d, read: read, &t)
        }
    }

    /// Model picks: every catalog id offered for `use` (Whisper and
    /// Parakeet), a fine-tune id, an unknown id (kept: fine-tunes and legacy
    /// bare ids are Whisper — ModelCatalog's rule).
    private static func model(_ key: String, _ path: ReferenceWritableKeyPath<Settings, String>,
                              use: ModelUse, default d: String, emits: SettingsChange) -> Option {
        Option(key: key, show: { $0[keyPath: path] }) { t in
            let read = { (s: Settings) in s[keyPath: path] }
            let catalog = ModelCatalog.sections(for: use).flatMap { $0 }.map(\.id)
            t.check(catalog.contains(where: { ModelCatalog.engine(of: $0) == .parakeet }),
                    "\(key): Parakeet is among the \(catalog.count) catalog picks")
            let ids = catalog + ["soumil-turbo-ft", "no-such-model-v9", "openai_whisper-small.en"]
            exercise(key, values: ids, emits: emits, read: read, write: { $0[keyPath: path] = $1 }, &t)
            let unknown = ids.filter { ModelCatalog.descriptor($0) == nil }
            t.check(unknown.allSatisfy { ModelCatalog.engine(of: $0) == .whisper
                        && ModelCatalog.resolve($0, for: use, custom: []) == nil },
                    "\(key): unknown and fine-tune ids route to Whisper and resolve to nothing (no crash)")
            loads(key, catalog.map { ($0, $0) } + [("", d), ("   ", d), ("\n", d), (5, d), (true, d),
                                                   (Data(d.utf8), d), ("no-such-model-v9", "no-such-model-v9")],
                  default: d, read: read, &t)
        }
    }

    private static func speedTier() -> Option {
        Option(key: "speedTier", show: { "\($0.speedTier)" }) { t in
            let read = { (s: Settings) in s.speedTier }
            let d = SpeedTier.relaxed.rawValue
            exercise("speedTier", values: SpeedTier.allCases.map(\.rawValue), emits: nil, read: read,
                     write: { $0.speedTier = $1 }, &t)
            let tiers = SpeedTier.allCases.map(\.rawValue)
            loads("speedTier", tiers.map { ($0, $0) } + [("1", 1), (1.0, 1), ("fast", d), ("", d),
                                                        (Double.nan, d), (1e300, d), (Data([0x02]), d)],
                  default: d, read: read, &t)
            // Raw values no tier has (a newer build's, a hand edit) resolve to
            // the fresh-install default, not the hungriest tier.
            var wrong: [Int] = []
            for raw in [-1, tiers.max()! + 1, 99, Int.max, Int.min] {
                if make(InMemoryStore(["speedTier": raw])).resolvedSpeedTier != .relaxed { wrong.append(raw) }
            }
            t.check(wrong.isEmpty, "speedTier: unknown tiers resolve to relaxed", "\(wrong)")
        }
    }

    private static func groundTruthModel() -> Option {
        Option(key: "groundTruthModel", show: { $0.groundTruthModel }) { t in
            let read = { (s: Settings) in s.groundTruthModel }
            // Every provider's labeling default, every on-device judge, a typed
            // id, and empty (the text field cleared).
            let ids = AssistantProvider.allCases.map(\.groundTruthDefaultModel).filter { !$0.isEmpty }
                + ModelCatalog.sections(for: .groundTruth).flatMap { $0 }.map(\.id)
                + ["google/gemma-3n-E4B-it", ""]
            exercise("groundTruthModel", values: ids, emits: nil, read: read,
                     write: { $0.groundTruthModel = $1 }, &t)
            loads("groundTruthModel", [("gpt-4o-audio-preview", "gpt-audio"), ("gpt-audio", "gpt-audio"),
                                       ("", ""), (5, "gpt-audio"), (Data(), "gpt-audio")],
                  default: "gpt-audio", read: read, &t)
        }
    }

    private static func assistantConfig() -> Option {
        Option(key: "assistantConfig", show: { s in
            let c = s.assistantConfig
            return c == .default ? "default" : "\(c.provider.rawValue) \(c.models.sorted { $0.key < $1.key })"
        }) { t in
            let read = { (s: Settings) in s.assistantConfig }
            var values: [AssistantConfig] = []
            for p in AssistantProvider.allCases {
                var c = AssistantConfig.default
                c.provider = p
                c.setModel("model-for-\(p.rawValue)", for: p)
                c.baseURL = p.needsBaseURL ? "http://localhost:11434/v1" : ""
                c.promptName = PromptLibrary.customName
                c.systemPrompt = "Answer in one line."
                c.attachScreenshot.toggle()
                c.fetchedModels = [p.rawValue: ["a", "b"]]
                values.append(c)
            }
            values.append(.default)
            exercise("assistantConfig", values: values, emits: nil, read: read,
                     write: { $0.assistantConfig = $1 }, &t)

            func json(_ s: String) -> Data { Data(s.utf8) }
            var kept = AssistantConfig.default
            kept.baseURL = "http://kept"
            kept.models = ["anthropic": "claude-x"]
            loads("assistantConfig", [
                (json("{}"), .default),
                (json(#"{"baseURL":"http://kept","models":{"anthropic":"claude-x"}}"#), kept),
                // A provider a newer build added: only that field falls back.
                (json(#"{"provider":"mistral","baseURL":"http://kept","models":{"anthropic":"claude-x"}}"#), kept),
                (json(#"{"provider":"openai","attachScreenshot":"yes","baseURL":"http://kept","models":{"anthropic":"claude-x"}}"#), kept),
                (json(#"{"provider":"openai","models":["not","a","map"],"baseURL":"http://kept"}"#),
                 { var c = AssistantConfig.default; c.baseURL = "http://kept"; return c }()),
                (json(#"{"provider":"gemini","unknownFutureField":42}"#),
                 { var c = AssistantConfig.default; c.provider = .gemini; return c }()),
                (json("[1,2]"), .default), (json("not json"), .default), (Data(), .default),
                (#"{"provider":"gemini"}"#, .default),   // a string, not data
            ], default: .default, read: read, &t)
        }
    }

    // MARK: Shortcuts

    private static let shortcutValues: [Hotkey] = [
        .fnDefault,
        Hotkey(modifiers: ctrl | alt, keyCode: nil, label: "⌃⌥"),
        Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /"),
        Hotkey(modifiers: cmd | ctrl, keyCode: 49, label: "⌃⌘ Space"),
        Hotkey(modifiers: ctrl, keyCode: nil, label: "⌃ ×2", taps: 2),
        Hotkey(modifiers: 0, keyCode: 96, label: "F5"),
    ]

    private static func describe(_ h: Hotkey?) -> String { h.map { "\($0.label)/\($0.taps)" } ?? "nil" }

    private static func slot(_ slot: BindingSlot) -> Option {
        let spec = slot.spec!
        return Option(key: spec.key, show: { describe($0.shortcut(for: slot)) }) { t in
            let read = { (s: Settings) in s.shortcut(for: slot) }
            let values: [Hotkey?] = shortcutValues + (spec.required ? [] : [nil])
            exercise(spec.key, values: values, emits: .bindings, dedupes: false, read: read,
                     write: { $0.setShortcut($1, for: slot) }, &t)

            // Every value reaches the monitor's binding list in each edition
            // that can run the action, and in no other.
            var wrong: [String] = []
            for value in values {
                let s = make(InMemoryStore())
                s.setShortcut(value, for: slot)
                for hasServer in [true, false] {
                    let caps = Capabilities(hasServer: hasServer)
                    let bound = HotkeyBinding.effective(from: s, capabilities: caps).first { $0.slot == slot }
                    let offered = slot.action.spec.isAvailable(in: caps)
                    if offered ? bound?.hotkey != value : bound != nil {
                        wrong.append("\(describe(value)) \(hasServer ? "Full" : "Lite")")
                    }
                }
            }
            t.check(wrong.isEmpty, "\(spec.key): every value binds in Full\(slot.action == .assist ? " only" : " and Lite")",
                    "\(wrong)")

            if spec.required {
                let s = make(InMemoryStore())
                s.setShortcut(nil, for: slot)
                t.equal(s.shortcut(for: slot), spec.defaultHotkey, "\(spec.key): can't be cleared")
            }

            // Stored forms. "Cleared" = empty data (today) or unreadable data;
            // a never-set or non-data key is the default. The required slot
            // reads anything unreadable as its default.
            let d = spec.defaultHotkey
            let cleared: Hotkey? = spec.required ? d : nil
            func json(_ s: String) -> Data { Data(s.utf8) }
            let chord = Hotkey(modifiers: alt, keyCode: 44, label: "⌥ /")
            loads(spec.key, [
                (json(#"{"modifiers":524288,"keyCode":44,"label":"⌥ /"}"#), chord),   // before `taps`
                (json(#"{"modifiers":524288,"keyCode":44,"label":"⌥ /","taps":1,"future":true}"#), chord),
                (json(#"{"modifiers":262144,"label":"⌃ ×2","taps":2}"#),
                 Hotkey(modifiers: ctrl, keyCode: nil, label: "⌃ ×2", taps: 2)),
                (Data(), cleared),
                (json("not json"), cleared),
                (json(#"{"modifiers":0,"label":"nothing to press"}"#), cleared),
                (json(#"{"modifiers":-1,"label":"x"}"#), cleared),
                (json(#"{"modifiers":524288,"keyCode":70000,"label":"x"}"#), cleared),
                (json(#"{"modifiers":524288}"#), cleared),
                (#"{"modifiers":524288,"keyCode":44,"label":"⌥ /"}"#, d),   // a string, not data
                (true, d), (7, d),
            ], default: d, read: read, &t)
        }
    }

    private static func toggle(_ slot: BindingSlot) -> Option {
        let key = slot.spec!.switchKey!
        return Option(key: key, show: { "\($0.isEnabled(slot))" }) { t in
            let read = { (s: Settings) in s.isEnabled(slot) }
            exercise(key, values: [false, true, false], emits: .bindings, dedupes: false, read: read,
                     write: { $0.setEnabled($1, for: slot) }, &t)
            let s = make(InMemoryStore())
            s.setEnabled(false, for: slot)
            let bound = HotkeyBinding.effective(from: s, capabilities: Capabilities(hasServer: true))
                .first { $0.slot == slot }
            t.check(bound?.enabled == false, "\(key): off reaches the monitor's binding list")
            loads(key, [(false, false), ("NO", false), ("0", false), ("garbage", true), ("", true),
                        (Data([0]), true)],
                  default: true, read: read, &t)
        }
    }

    // MARK: - Same-value writes

    /// The Nov 13 freeze's shape: a view body writes a setting, the write
    /// publishes, SwiftUI re-runs the body. With same-value writes silent it
    /// settles on the second pass (the first one's real change re-renders).
    private static func sameValueWrites(_ t: inout Checks) {
        let s = make(InMemoryStore())
        var dirty = true
        var renders = 0
        var events = 0
        var bag: Set<AnyCancellable> = []
        s.objectWillChange.sink { dirty = true }.store(in: &bag)
        s.changes.sink { _ in events += 1 }.store(in: &bag)
        while dirty, renders < 50 {
            dirty = false
            renders += 1
            s.overlayOpacity = 0.6
            s.whisperModel = s.whisperModel
            s.assistantConfig = s.assistantConfig
            s.groundTruthRecipe = s.groundTruthRecipe
        }
        t.check(renders == 2 && events == 0, "a body writing settings settles: one real change, then silence",
                "\(renders) renders, \(events) events")

        var wills = 0
        let nan = make(InMemoryStore())
        nan.objectWillChange.sink { wills += 1 }.store(in: &bag)
        nan.captureMaxGB = .nan
        nan.captureMaxGB = .nan
        t.equal(wills, 1, "NaN over NaN is no change (NaN ≠ NaN must not publish every write)")
        t.equal(make(InMemoryStore(["captureMaxGB": Double.nan])).captureMaxGB, 2,
                "…and a stored NaN still reads as the default")
    }

    /// A Settings over `store` that skips the login-item query (~40 ms
    /// each; this suite builds ~1,100).
    private static func make(_ store: KeyValueStore) -> Settings {
        Settings(store: store, loginItemEnabled: { false })
    }

    // MARK: - Snapshots

    private static func snapshot(_ s: Settings) -> [String: String] {
        Dictionary(uniqueKeysWithValues: options.map { ($0.key, $0.show(s)) })
    }

    // MARK: - Fresh install

    private static func freshInstall(_ t: inout Checks) {
        let store = InMemoryStore()
        let s = make(store)
        // The whole default snapshot: changing a default is a deliberate edit here.
        let expected: [String: String] = [
            "hotkey": "fn 🌐/1", "dictateToggleHotkey": "⌃ ×2/2", "assistantHotkey": "⌃fn/1",
            "streamHotkey": "nil", "streamToggleHotkey": "nil",
            "dictateHoldOn": "true", "dictateToggleOn": "true", "streamHoldOn": "true", "streamToggleOn": "true",
            "autoInsert": "true", "hotwords": "", "contextPrompt": "",
            "holdActivationDelay": "0.0", "overlayOpacity": "0.4", "pillOnRight": "false", "speedTier": "2",
            "whisperModel": "tiny.en", "continuousModel": "parakeet-ultra", "continuousTypeCPS": "80.0",
            "echoCancellation": "false", "inputDeviceUID": "", "inputDeviceName": "",
            "assistantConfig": "default", "localQuantized": "true",
            "localMemLimitGB": "\(Settings.localMemDefaultGB(ramGB: MachineProfile.ramGB))",
            "captureEdits": "true", "captureMaxGB": "2.0",
            "groundTruthProvider": "openai", "groundTruthModel": "gpt-audio", "groundTruthBaseURL": "",
            "groundTruthPrompt": "", "consensusPrompt": "", "groundTruthRecipe": "consensusFormat",
            "autoLabelNew": "true", "verboseLogging": "false", "reportProblems": "true",
        ]
        let got = snapshot(s)
        let diff = Set(expected.keys).union(got.keys).filter { expected[$0] != got[$0] }.sorted()
        t.check(diff.isEmpty, "fresh install: all \(expected.count) defaults as documented",
                diff.map { "\($0): \(got[$0] ?? "-") ≠ \(expected[$0] ?? "-")" }.joined(separator: "; "))
        let c = AssistantConfig.default
        t.check(c.provider == .openai && c.models == ["openai": "gpt-5.4-mini"] && c.baseURL.isEmpty
                && c.promptName == "rewrite" && c.attachScreenshot && c.fetchedModels.isEmpty
                && c.systemPrompt == AssistantConfig.defaultSystemPrompt,
                "fresh install: assistant config defaults as documented")
        t.check(store.values.isEmpty, "fresh install: loading defaults writes nothing")

        // Internally consistent, and valid by the same rules the UI applies.
        let dictation = ModelCatalog.descriptor(s.whisperModel)
        t.check(dictation?.bundled == true && ModelCatalog.resolve(s.whisperModel, for: .dictation, custom: []) != nil,
                "default dictation model is bundled (dictates offline in Full and Lite)")
        t.check(ModelCatalog.resolve(s.continuousModel, for: .continuous, custom: []) != nil,
                "default live-typing model is a catalog pick for live typing")
        t.check(ProviderCatalog.groundTruthChoices.contains(s.groundTruthProvider)
                && s.groundTruthModel == s.groundTruthProvider.groundTruthDefaultModel,
                "default labeler is offered and its model is that provider's default")
        t.check(AssistantProvider.assistantChoices.contains(s.assistantConfig.provider),
                "default assistant provider is offered")
        t.check(SpeedTier(rawValue: s.speedTier) != nil, "default speed tier is a real tier")
        let defaults = ActionSpec.all.flatMap(\.slots).compactMap { $0.spec?.defaultHotkey }
        t.check(defaults.allSatisfy(\.isValid), "every default shortcut is pressable")
        for hasServer in [true, false] {
            let bound = HotkeyBinding.effective(from: s, capabilities: Capabilities(hasServer: hasServer))
                .filter { $0.enabled && $0.hotkey != nil }
            let shapes = bound.map { "\($0.style)|\($0.hotkey!.modifiers)|\(String(describing: $0.hotkey!.keyCode))|\($0.hotkey!.taps)" }
            t.check(Set(shapes).count == shapes.count && bound.contains { $0.slot == .dictation }
                    && bound.contains { $0.action == .assist } == hasServer,
                    "\(hasServer ? "Full" : "Lite"): \(bound.count) default shortcuts, distinct, dictation bound")
        }
        // The memory limit's default and ceiling stay ordered on every Mac.
        let rams = [0, 1, 2, 4, 6, 8, 12, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 512]
        let bad = rams.filter { ram in
            let d = Settings.localMemDefaultGB(ramGB: ram), hi = Settings.localMemMaxGB(ramGB: ram)
            return !(Settings.localMemMinGB <= d && d <= hi)
        }
        t.check(bad.isEmpty, "memory limit: floor ≤ default ≤ ceiling for \(rams.count) RAM sizes", "\(bad)")
    }

    // MARK: - Migrations

    /// Every migration the settings code runs (the per-key ones — the retired
    /// gpt-4o-audio-preview, clamps, blank model ids, legacy hotkey forms,
    /// missing config fields — are in each option's stored forms above).
    private static func migrations(_ t: inout Checks) {
        let marker = Settings.customFourMigrationKey
        // Custom 4: the stored old default moves once; a pick, or the marker,
        // keeps whatever is stored.
        let cases: [(stored: [String: Any], reads: GroundTruthRecipe, marks: Bool)] = [
            ([:], .consensusFormat, false),
            (["groundTruthRecipe": "consensus"], .consensusFormat, true),
            (["groundTruthRecipe": "consensus", marker: true], .consensus, true),
            (["groundTruthRecipe": "consensus", marker: false], .consensusFormat, true),
            (["groundTruthRecipe": "single"], .single, false),
            (["groundTruthRecipe": "consensusFormat"], .consensusFormat, false),
            (["groundTruthRecipe": "custom3"], .consensusFormat, false),
            ([marker: true], .consensusFormat, true),
        ]
        var wrong: [String] = []
        for c in cases {
            let store = InMemoryStore(c.stored)
            let s = make(store)
            let again = make(store)
            if s.groundTruthRecipe != c.reads || again.groundTruthRecipe != c.reads
                || store.bool(forKey: marker) != c.marks {
                wrong.append("\(c.stored) → \(s.groundTruthRecipe), marker \(store.bool(forKey: marker))")
            }
        }
        t.check(wrong.isEmpty, "Custom 4 migration: \(cases.count) stored states, idempotent", "\(wrong)")

        // A whole plist of the wrong kinds (another app's, a corrupted one)
        // loads as a fresh install, migrations included.
        let alien = InMemoryStore(Dictionary(uniqueKeysWithValues: (options.map(\.key) + ["didFirstRun", marker])
            .map { ($0, Date(timeIntervalSince1970: 0) as Any) }))
        let s = make(alien)
        t.equal(snapshot(s), snapshot(make(InMemoryStore())), "a plist of wrong-kind values loads as defaults")
        t.check(s.isFirstRun, "…and as a first run")
    }
}
