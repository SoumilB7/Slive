import Foundation

// G3 — upgrade replay. A fresh install is the only state the self-tests used
// to see; real users arrive with the prefs an older release left behind.
// Each fixture in Fixtures/gauntlet/prefs/<version>.json holds what a few
// realistic users of that release had stored, plus the decision table that
// release itself computed from them (hand-read from its sources at the
// commit named in the fixture). This build must reach the same table, or the
// difference must be listed in intended-migrations.txt.

/// Where the Gauntlet's fixture files live. Resolved from this source file,
/// so a run works from any working directory.
enum GauntletFixtureFiles {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Gauntlet
        .deletingLastPathComponent()   // Slive
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // Frontend
        .appendingPathComponent("Fixtures/gauntlet", isDirectory: true)

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    static func json(_ relative: String) -> [String: Any]? {
        (try? Data(contentsOf: url(relative)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func text(_ relative: String) -> String? {
        try? String(contentsOf: url(relative), encoding: .utf8)
    }
}

/// One released version's stored prefs for one kind of user, and the table
/// that version computed from them.
struct UpgradeProfile {
    let version: String
    let name: String
    /// Values as the release wrote them to UserDefaults.
    let stored: [String: Any]
    let expected: [String: String]

    /// Fixture JSON → the Foundation values UserDefaults would hold: an
    /// object is a JSON `Data` blob (shortcuts, assistantConfig), the marker
    /// string is the empty `Data` a cleared shortcut leaves behind.
    static func storedValues(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in raw {
            if let text = value as? String, text == "<empty data>" {
                out[key] = Data()
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value) {
                out[key] = data
            } else {
                out[key] = value
            }
        }
        return out
    }

    static func tableValues(_ raw: [String: Any]) -> [String: String] {
        raw.mapValues { value in
            if let text = value as? String { return text }
            if let flag = value as? Bool { return flag ? "true" : "false" }
            return "\(value)"
        }
    }
}

/// What a user would notice: does Slive upload, what does it ask, does it
/// type, which shortcuts act. Computed from a loaded `Settings` the same way
/// for every release, so two tables are comparable field by field.
enum UpgradeDecisionTable {
    static func compute(_ settings: Settings) -> [String: String] {
        func shortcut(_ slot: BindingSlot) -> String {
            let hotkey = settings.shortcut(for: slot)
            var text = "none"
            if let hotkey {
                text = "m\(hotkey.modifiers)"
                if let key = hotkey.keyCode { text += "+k\(key)" }
                if hotkey.taps != 1 { text += "x\(hotkey.taps)" }
            }
            return settings.isEnabled(slot) ? text : text + "|off"
        }
        let config = settings.assistantConfig
        return [
            "autoLabelNew": "\(settings.autoLabelNew)",
            "assistantProvider": config.provider.rawValue,
            "assistantPrompt": config.promptName,
            "attachScreenshot": "\(config.attachScreenshot)",
            "autoInsert": "\(settings.autoInsert)",
            "dictationModel": settings.whisperModel,
            "shortcut.dictation": shortcut(.dictation),
            "shortcut.dictationToggle": shortcut(.dictationToggle),
            "shortcut.assistant": shortcut(.assistant),
            "shortcut.stream": shortcut(.stream),
            "shortcut.streamToggle": shortcut(.streamToggle),
        ]
    }

    static let fields = ["autoLabelNew", "assistantProvider", "assistantPrompt", "attachScreenshot",
                         "autoInsert", "dictationModel", "shortcut.dictation", "shortcut.dictationToggle",
                         "shortcut.assistant", "shortcut.stream", "shortcut.streamToggle"]
}

/// intended-migrations.txt: `<version> <profile|*> <field> <old> -> <new>  # changelog 0.2.N: why`.
struct IntendedMigrations {
    struct Entry { let version: String; let profile: String; let field: String; let old: String; let new: String; let note: String }
    private(set) var entries: [Entry] = []
    private(set) var malformed: [String] = []

    init(text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: " # ")
            let words = parts[0].split(separator: " ").map(String.init)
            guard words.count == 6, words[4] == "->" else { malformed.append(line); continue }
            entries.append(Entry(version: words[0], profile: words[1], field: words[2],
                                 old: words[3], new: words[5],
                                 note: parts.count > 1 ? parts[1...].joined(separator: " # ") : ""))
        }
    }

    /// Is moving `field` from `old` to `new` for this user a listed migration?
    func lists(version: String, profile: String, field: String, old: String, new: String) -> Bool {
        entries.contains {
            $0.version == version && ($0.profile == "*" || $0.profile == profile)
                && $0.field == field && $0.old == old && $0.new == new
        }
    }
}

@MainActor enum UpgradeFamily {
    static let versions = ["0.2.0", "0.2.1", "0.2.2", "0.2.3", "0.2.4", "0.2.5", "0.2.6"]

    static let family = GauntletFamily(name: "upgrade", seeded: false) { UpgradeFamily.run(&$0) }

    /// The check id a differing field answers to: the 0.2.5 findings it
    /// reproduces, else the family's own.
    static func checkID(field: String, profile: String) -> String {
        if field == "autoLabelNew" { return "F1" }
        if profile == "carried", ["assistantProvider", "assistantPrompt", "attachScreenshot"].contains(field) { return "F2" }
        return "upgrade.drift"
    }

    static func run(_ run: inout GauntletRun) {
        let migrationsText = GauntletFixtureFiles.text("intended-migrations.txt")
        let migrations = IntendedMigrations(text: migrationsText ?? "")
        run.check(migrationsText != nil && migrations.malformed.isEmpty, id: "upgrade.migrations-file",
                  "intended-migrations.txt is readable and every line parses",
                  migrations.malformed.joined(separator: " | "))
        let changelog = (try? String(contentsOf: GauntletFixtureFiles.root
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md"), encoding: .utf8)) ?? ""
        let undocumented = migrations.entries.filter { entry in
            guard let range = entry.note.range(of: #"changelog 0\.\d+\.\d+"#, options: .regularExpression)
            else { return true }
            let version = entry.note[range].dropFirst("changelog ".count)
            return !changelog.contains("## [\(version)]")
        }
        run.check(undocumented.isEmpty, id: "upgrade.migrations-documented",
                  "every intended migration cites a CHANGELOG release",
                  undocumented.map { "\($0.version) \($0.field)" }.joined(separator: ", "))

        for version in versions {
            guard let file = GauntletFixtureFiles.json("prefs/\(version).json"),
                  file["version"] as? String == version,
                  let rawProfiles = file["profiles"] as? [[String: Any]] else {
                run.check(false, id: "upgrade.drift", "\(version): fixture prefs/\(version).json is present and names its version")
                continue
            }
            var bad: [String: [String]] = [:]   // check id → what differed
            var misshapen: [String] = []
            for raw in rawProfiles {
                guard let name = raw["name"] as? String, let stored = raw["stored"] as? [String: Any],
                      let expectedRaw = raw["expected"] as? [String: Any] else {
                    bad["upgrade.drift", default: []].append("malformed profile")
                    continue
                }
                let profile = UpgradeProfile(version: version, name: name,
                                             stored: UpgradeProfile.storedValues(stored),
                                             expected: UpgradeProfile.tableValues(expectedRaw))
                let settings = Settings(store: InMemoryStore(profile.stored), loginItemEnabled: { false })
                let actual = UpgradeDecisionTable.compute(settings)
                // A table that skips a field would let it drift unseen.
                if Set(profile.expected.keys) != Set(UpgradeDecisionTable.fields) { misshapen.append(name) }
                for field in UpgradeDecisionTable.fields {
                    let old = profile.expected[field] ?? "(missing in fixture)"
                    let new = actual[field] ?? "(missing)"
                    if old == new
                        || migrations.lists(version: version, profile: name, field: field, old: old, new: new) { continue }
                    bad[checkID(field: field, profile: name), default: []]
                        .append("\(name).\(field) \(old) → \(new)")
                }
            }
            // One line per id so the ledger can match failures to findings.
            for id in ["F1", "F2", "upgrade.drift"] {
                let what: String
                switch id {
                case "F1": what = "paid auto-labeling stays off unless the user turned it on"
                case "F2": what = "an old assistant config keeps its provider, prompt and screenshot setting"
                default: what = "every other decision matches (or is a listed migration)"
                }
                run.check(bad[id] == nil, id: id, "\(version): \(what)", (bad[id] ?? []).joined(separator: "; "))
            }
            run.check(misshapen.isEmpty && rawProfiles.count >= 3, id: "upgrade.fixtures",
                      "\(version): fixture has the untouched, customized and carried users, each with every field",
                      misshapen.joined(separator: ", "))
        }
    }
}
