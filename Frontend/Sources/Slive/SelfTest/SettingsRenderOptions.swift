import CoreGraphics
import Foundation

/// One thing a user can configure that changes what Settings draws, and
/// every value it can take. Values come from the code that defines them
/// (catalogs, enums, `@Stored` declarations, `ActionSpec`), so a new model,
/// provider, recipe, tier, shortcut or setting is rendered without anyone
/// remembering to list it here.
struct RenderOption {
    let name: String
    let values: [String]
    /// The `Settings` keys (or `AssistantConfig.<field>`, `Grants.<field>`)
    /// this option sets — the completeness checks compare them to the code.
    var keys: [String] = []
    /// Applies value `i`. Options apply in list order.
    var apply: (Int, inout RenderSetup) -> Void = { _, _ in }
}

/// Every Settings configuration option and an all-pairs covering set over
/// them: each value of each option is drawn beside each value of every other
/// option at least once. Where a view is drawn — page, alone or in the
/// window shell, width tier, edition — are options too, so every value is
/// drawn on every page, at every tier, in both editions.
enum RenderOptions {
    // MARK: - Where (the first four options; no setup)

    static let pageIndex = 0, hostIndex = 1, widthIndex = 2, editionIndex = 3

    static let pages = SettingsRegistry.all.map(\.id)
    static let editions = [("Full", SettingsRenderTests.full), ("Lite", SettingsRenderTests.lite)]
    /// Lite's pages (a Full-only page can't be drawn in Lite).
    static let litePages = Set(SettingsRegistry.pages(for: SettingsRenderTests.lite).map(\.id))

    // MARK: - Fixture values

    /// The fixture fine-tune's id (`RenderWorld.fineTune`).
    static let fineTuneID = "soumil-turbo-ft"
    /// An id no catalog or fine-tune knows (a retired model, a hand edit).
    static let staleModelID = "large-v2-retired"
    static let longText = (1...24).map { "Line \($0): Kubernetes, PostgreSQL, Soumil, WhisperKit, Parakeet." }
        .joined(separator: "\n")
    /// ⌥⇧K — a shortcut no default uses.
    static let customHotkey = Hotkey(modifiers: 655_360, keyCode: 40, label: "⌥⇧ K")

    /// Stored-value edges per Double setting: the default first, then the
    /// slider's ends or values past them (old builds and hand edits store
    /// those). A Double setting not listed gets `[default, 0, 10× + 1]`.
    static let doubleEdges: [String: [Double]] = [
        "holdActivationDelay": [0.6, 5],
        "overlayOpacity": [0, 1],
        "continuousTypeCPS": [12, 120],
        "captureMaxGB": [0.001, 20],   // 0.001: any data is over the limit
        "localMemLimitGB": [2, 999],   // 999 is clamped on read
    ]

    /// The speech-model state of a picked model. The switch maps every
    /// `ModelStatus`, so a new status doesn't compile until it has a value.
    enum ModelState: String, CaseIterable {
        case notDownloaded, downloading, loading, ready, failed

        init(_ status: ModelStatus) {
            switch status {
            case .notDownloaded: self = .notDownloaded
            case .downloading: self = .downloading
            case .preparing: self = .loading
            case .ready: self = .ready
            case .failed: self = .failed
            }
        }

        func apply(to model: String, _ s: inout RenderSetup) {
            switch self {
            case .notDownloaded:
                s.onDisk.remove(model)
            case .downloading:
                s.onDisk.remove(model)
                s.statuses[model] = .downloading(0.42)
            case .loading:
                s.onDisk.insert(model)
                s.slowLoads.insert(model)
                s.statuses[model] = .preparing("Loading")
            case .ready:
                s.onDisk.insert(model)
            case .failed:
                s.statuses[model] = .failed("Download failed: The Internet connection appears to be offline.")
            }
        }
    }

    /// The states a model id can really be in: a bundled model or an
    /// installed fine-tune is always on disk; an unknown id never loads.
    static func states(for model: String) -> Set<ModelState> {
        if model == staleModelID { return [.notDownloaded, .failed] }
        if model == fineTuneID || ModelCatalog.descriptor(model)?.bundled == true {
            return [.loading, .ready, .failed]
        }
        return Set(ModelState.allCases)
    }

    // MARK: - The options

    /// `@Stored` keys handled by a dedicated option below (not generically).
    static let dedicatedKeys: Set<String> = [
        "whisperModel", "continuousModel", "groundTruthModel", "inputDeviceUID", "inputDeviceName",
        "speedTier", "assistantConfig",
    ]

    static let all: [RenderOption] = build()

    private static func build() -> [RenderOption] {
        var o: [RenderOption] = [
            RenderOption(name: "page", values: pages.map(\.rawValue)),
            RenderOption(name: "host", values: ["alone", "shell"]),
            RenderOption(name: "width", values: SettingsRenderTests.widths.map { "\($0.0)" }),
            RenderOption(name: "edition", values: editions.map(\.0)),
        ]

        // Speech models: every catalog model offered for the use, the
        // fine-tune and a stale id; and what's on disk around them.
        let dictation = ModelCatalog.sections(for: .dictation).flatMap { $0 }.map(\.id) + [fineTuneID, staleModelID]
        let continuous = ModelCatalog.sections(for: .continuous).flatMap { $0 }.map(\.id) + [fineTuneID, staleModelID]
        o.append(stringOption("dictation model", key: "whisperModel", dictation))
        o.append(stringOption("live typing model", key: "continuousModel", continuous))
        var judges = ["gpt-audio", "", "gpt-4o-audio-preview"]   // default, unset, the migrated retired id
        for model in ProviderCatalog.all.compactMap(\.groundTruthDefaultModel) where !judges.contains(model) {
            judges.append(model)
        }
        o.append(stringOption("ground-truth model", key: "groundTruthModel", judges))
        o.append(RenderOption(name: "fine-tune installed", values: ["no", "yes"]) { i, s in s.fineTune = i == 1 })
        o.append(RenderOption(name: "other models on disk", values: ["none", "every catalog model"]) { i, s in
            if i == 1 { s.onDisk.formUnion(ModelCatalog.all.map(\.id)) }
        })
        o.append(RenderOption(name: "speed tier", values: SpeedTier.allCases.map(\.label) + ["unknown stored tier"],
                              keys: ["speedTier"]) { i, s in
            s.stored["speedTier"] = i < SpeedTier.allCases.count ? SpeedTier.allCases[i].rawValue : 99
        })

        // Every other @Stored setting, by type.
        o += storedOptions()

        // The assistant config, field by field.
        o += assistantOptions()

        // Keys: every provider that takes one, and the Hugging Face token.
        for p in ProviderCatalog.keyed {
            o.append(RenderOption(name: "\(p.rawValue) key", values: ["absent", "present"]) { i, s in
                if i == 1 { s.secrets[CredentialStore.account(for: p)] = "render-key-\(p.rawValue)" }
            })
        }
        o.append(RenderOption(name: "Hugging Face token", values: ["absent", "present"]) { i, s in
            if i == 1 { s.secrets[CredentialStore.hfAccount] = "hf_render_fixture" }
        })

        // Shortcuts: every slot set by default, cleared (where allowed) or
        // custom; every on/off switch.
        for slot in ActionSpec.all.flatMap(\.slots) {
            guard let spec = slot.spec else { continue }
            let values = spec.required ? ["default", "custom"] : ["default", "cleared", "custom"]
            o.append(RenderOption(name: "\(slot.action) \(slot.style) shortcut", values: values,
                                  keys: [spec.key]) { i, s in
                guard i > 0 else { return }
                let mem = InMemoryStore()
                spec.writeShortcut(values[i] == "custom" ? customHotkey : nil, to: mem)
                s.stored.merge(mem.values) { $1 }
            })
            if let key = spec.switchKey {
                o.append(RenderOption(name: "\(slot.action) \(slot.style) switch", values: ["on", "off"],
                                      keys: [key]) { i, s in
                    if i == 1 { s.stored[key] = false }
                })
            }
        }

        o.append(RenderOption(name: "turbo suggestion", values: ["showing", "dismissed"]) { i, s in
            s.balancedDismissed = i == 1
        })
        o.append(RenderOption(name: "live typing suggestion", values: ["showing", "dismissed"]) { i, s in
            s.liveTypingDismissed = i == 1
        })

        // Permissions, each granted or denied.
        let grants: [(String, WritableKeyPath<PermissionsModel.Grants, Bool>)] =
            [("mic", \.mic), ("inputMonitoring", \.inputMonitoring), ("accessibility", \.accessibility)]
        for (name, path) in grants {
            o.append(RenderOption(name: "\(name) permission", values: ["denied", "granted"],
                                  keys: ["Grants.\(name)"]) { i, s in s.grants[keyPath: path] = i == 1 })
        }
        o.append(RenderOption(name: "hotkey proven working", values: ["no", "yes"]) { i, s in s.hotkeyActive = i == 1 })

        o.append(RenderOption(
            name: "microphone",
            values: ["system default", "built-in picked", "Bluetooth headset picked", "picked, unplugged", "no microphones"],
            keys: ["inputDeviceUID", "inputDeviceName"]) { i, s in
            switch i {
            case 1: s.stored["inputDeviceUID"] = RenderWorld.builtIn.uid; s.stored["inputDeviceName"] = RenderWorld.builtIn.name
            case 2: s.stored["inputDeviceUID"] = RenderWorld.headset.uid; s.stored["inputDeviceName"] = RenderWorld.headset.name
            case 3: s.stored["inputDeviceUID"] = "USB-Yeti-0042"; s.stored["inputDeviceName"] = "Yeti Stereo Microphone"
            case 4: s.devices = []; s.systemDefault = nil
            default: break
            }
        })

        // Captured data, the training server, history, logs.
        o.append(RenderOption(name: "training data", values: TrainingData.allCases.map { "\($0) (\($0.rawValue))" }) {
            i, s in s.training = TrainingData.allCases[i]
        })
        o.append(RenderOption(name: "training job", values: JobScript.allCases.map(\.rawValue)) { i, s in
            s.job = JobScript.allCases[i]
        })
        o.append(RenderOption(name: "training readiness", values: ["not ready", "ready"]) { i, s in s.trainingReady = i == 1 })
        o.append(RenderOption(name: "local model cache", values: ["empty", "models"]) { i, s in
            if i == 1 { s.localCache = RenderSetup.cachedModels }
        })
        o.append(RenderOption(name: "history", values: ["empty", "entries"]) { i, s in
            if i == 1 { s.history = RenderWorld.historyTexts + [longText] }
        })
        o.append(RenderOption(name: "assistant prompt log", values: ["empty", "recorded"]) { i, s in s.promptLog = i == 1 })
        o.append(RenderOption(name: "speaking stats", values: ["none", "recorded"]) { i, s in
            if i == 1 { s.stored.merge(["wpm.last": 212.0, "wpm.average": 176.0, "wpm.best": 241.0, "wpm.count": 58]) { $1 } }
        })

        // Last: the picked models' states (they override "on disk").
        o.append(RenderOption(name: "dictation model state", values: ModelState.allCases.map(\.rawValue)) { i, s in
            ModelState.allCases[i].apply(to: s.stored["whisperModel"] as? String ?? ModelCatalog.defaultDictation, &s)
        })
        o.append(RenderOption(name: "live typing model state", values: ModelState.allCases.map(\.rawValue)) { i, s in
            ModelState.allCases[i].apply(to: s.stored["continuousModel"] as? String ?? ModelCatalog.defaultContinuous, &s)
        })
        return o
    }

    private static func stringOption(_ name: String, key: String, _ values: [String]) -> RenderOption {
        RenderOption(name: name, values: values.map { $0.isEmpty ? "(empty)" : $0 }, keys: [key]) { i, s in
            s.stored[key] = values[i]
        }
    }

    /// One option per `@Stored` setting not handled above, its values by
    /// type: both Bools, Double edges, every enum case, empty or long text.
    /// A setting of any other type gets no option, which the suite's
    /// completeness check reports.
    private static func storedOptions() -> [RenderOption] {
        var out: [RenderOption] = []
        for child in Mirror(reflecting: Settings(store: InMemoryStore())).children {
            guard let stored = child.value as? AnyStoredSetting, !dedicatedKeys.contains(stored.key) else { continue }
            let key = stored.key
            switch child.value {
            case let b as Stored<Bool>:
                let d = b.setting.defaultValue
                out.append(RenderOption(name: key, values: ["\(d) (default)", "\(!d)"], keys: [key]) { i, s in
                    if i == 1 { s.stored[key] = !d }
                })
            case let x as Stored<Double>:
                let d = x.setting.defaultValue
                let values = [d] + (doubleEdges[key] ?? [0, d * 10 + 1])
                out.append(RenderOption(name: key, values: values.map { "\($0)" }, keys: [key]) { i, s in
                    if i > 0 { s.stored[key] = values[i] }
                })
            case let n as Stored<Int>:
                let d = n.setting.defaultValue
                out.append(RenderOption(name: key, values: ["\(d)", "0", "-1"], keys: [key]) { i, s in
                    if i > 0 { s.stored[key] = [d, 0, -1][i] }
                })
            case is Stored<String>:
                out.append(RenderOption(name: key, values: ["(empty)", "long text"], keys: [key]) { i, s in
                    if i == 1 { s.stored[key] = longText }
                })
            case is Stored<AssistantProvider>:
                out.append(enumOption(key, AssistantProvider.allCases))
            case is Stored<GroundTruthRecipe>:
                var option = enumOption(key, GroundTruthRecipe.allCases)
                let set = option.apply
                option.apply = { i, s in
                    set(i, &s)
                    s.stored[Settings.customFourMigrationKey] = true   // a pick is final
                }
                out.append(option)
            default:
                break
            }
        }
        return out
    }

    private static func enumOption<E: RawRepresentable>(_ key: String, _ cases: [E]) -> RenderOption
    where E.RawValue == String {
        RenderOption(name: key, values: cases.map(\.rawValue), keys: [key]) { i, s in s.stored[key] = cases[i].rawValue }
    }

    /// `AssistantConfig` field by field (one JSON setting in the store).
    private static func assistantOptions() -> [RenderOption] {
        func field(_ name: String, _ values: [String], _ edit: @escaping (Int, inout AssistantConfig) -> Void) -> RenderOption {
            RenderOption(name: "assistant \(name)", values: values, keys: ["assistantConfig", "AssistantConfig.\(name)"]) { i, s in
                var config = s.assistantConfig ?? .default
                edit(i, &config)
                s.assistantConfig = config
            }
        }
        let providers = AssistantProvider.allCases
        return [
            field("provider", providers.map(\.rawValue)) { i, c in c.provider = providers[i] },
            field("models", ["default", "empty override", "custom for every provider"]) { i, c in
                if i == 1 { c.models = Dictionary(uniqueKeysWithValues: providers.map { ($0.rawValue, "") }) }
                if i == 2 { c.models = Dictionary(uniqueKeysWithValues: providers.map { ($0.rawValue, "render-model-9") }) }
            },
            field("baseURL", ["(empty)", "set"]) { i, c in if i == 1 { c.baseURL = "http://localhost:11434/v1" } },
            field("promptName", ["rewrite", "(custom)", "deleted prompt"]) { i, c in
                c.promptName = ["rewrite", "", "deleted-prompt"][i]
            },
            field("systemPrompt", ["default", "(empty)", "long"]) { i, c in
                if i == 1 { c.systemPrompt = "" }
                if i == 2 { c.systemPrompt = longText }
            },
            field("attachScreenshot", ["on", "off"]) { i, c in c.attachScreenshot = i == 0 },
            field("fetchedModels", ["none", "every provider", "empty lists"]) { i, c in
                if i == 1 {
                    c.fetchedModels = Dictionary(uniqueKeysWithValues: providers.map {
                        ($0.rawValue, ["\($0.rawValue)-large", "\($0.rawValue)-mini", "render-model-9"])
                    })
                }
                if i == 2 { c.fetchedModels = Dictionary(uniqueKeysWithValues: providers.map { ($0.rawValue, []) }) }
            },
        ]
    }

    // MARK: - Constraints

    static let index: [String: Int] = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.name, $0) })

    /// False when a (partial) row is a configuration no user can have.
    /// Constraints are pairwise or tie two models' states, so every allowed
    /// pair also fits in a full row.
    static func allows(_ row: [Int?]) -> Bool {
        func value(_ name: String) -> String? {
            guard let f = index[name], let v = row[f] else { return nil }
            return all[f].values[v]
        }
        if let page = row[pageIndex], let edition = row[editionIndex],
           !editions[edition].1.server, !litePages.contains(pages[page]) { return false }
        let fineTune = value("fine-tune installed")
        var picked: [(model: String, state: String?)] = []
        for (model, state) in [("dictation model", "dictation model state"), ("live typing model", "live typing model state")] {
            guard let m = value(model) else { continue }
            if m == fineTuneID, fineTune == "no" { return false }
            let st = value(state)
            if let st, let typed = ModelState(rawValue: st), !states(for: m).contains(typed) { return false }
            picked.append((m, st))
        }
        if picked.count == 2, picked[0].model == picked[1].model,
           let a = picked[0].state, let b = picked[1].state, a != b { return false }
        return true
    }

    // MARK: - Rows

    /// The covering set: one row (a value per option) per view.
    static let rows: [[Int]] = AllPairs.rows(sizes: all.map(\.values.count), allows: allows)

    static func setup(row: [Int]) -> RenderSetup {
        var s = RenderSetup()
        for (f, option) in all.enumerated() { option.apply(row[f], &s) }
        if let config = s.assistantConfig {
            let mem = InMemoryStore()
            config.write(to: mem, key: "assistantConfig")
            s.stored.merge(mem.values) { $1 }
        }
        return s
    }

    /// Where the row's view is drawn.
    static func placement(_ row: [Int]) -> (host: SettingsRenderTests.Host, width: CGFloat, caps: Capabilities) {
        let page = pages[row[pageIndex]]
        let host: SettingsRenderTests.Host = row[hostIndex] == 0 ? .page(page) : .shell(page)
        return (host, SettingsRenderTests.widths[row[widthIndex]].1, editions[row[editionIndex]].1)
    }

    /// The row's non-default values (index 0 is each option's default), for
    /// failure messages.
    static func describe(_ row: [Int]) -> String {
        all.indices.filter { $0 > editionIndex && row[$0] != 0 }
            .map { "\(all[$0].name)=\(all[$0].values[row[$0]])" }.joined(separator: ", ")
    }
}

/// A greedy all-pairs covering array (AETG-style, deterministic): each row
/// starts from the first pair still uncovered and fills the other factors,
/// largest first, with the value that covers the most new pairs beside what's
/// already chosen (ties: the value used least so far).
enum AllPairs {
    /// Rows over factors with `sizes` values each, covering every pair of
    /// values that `allows` permits (it sees partial rows; nil = unset).
    static func rows(sizes: [Int], allows: ([Int?]) -> Bool) -> [[Int]] {
        var pairs = Pairs(sizes: sizes, allows: allows)
        let order = sizes.indices.sorted { (sizes[$0], -$0) > (sizes[$1], -$1) }
        var uses = sizes.map { [Int](repeating: 0, count: $0) }
        var rows: [[Int]] = []
        while let (a, va, b, vb) = pairs.firstNeeded() {
            var row = [Int?](repeating: nil, count: sizes.count)
            row[a] = va
            row[b] = vb
            for f in order where row[f] == nil {
                var best = 0, bestGain = -1, bestUse = Int.max
                for v in 0..<sizes[f] {
                    row[f] = v
                    guard allows(row) else { continue }
                    let gain = pairs.gain(f, v, row)
                    if gain > bestGain || (gain == bestGain && uses[f][v] < bestUse) {
                        (best, bestGain, bestUse) = (v, gain, uses[f][v])
                    }
                }
                row[f] = best
            }
            let full = row.map { $0 ?? 0 }
            for (f, v) in full.enumerated() { uses[f][v] += 1 }
            pairs.cover(full)
            rows.append(full)
        }
        return rows
    }

    /// The allowed pairs `rows` leaves uncovered — an independent recount,
    /// not the generator's own bookkeeping.
    static func missing(_ rows: [[Int]], sizes: [Int], allows: ([Int?]) -> Bool) -> [(Int, Int, Int, Int)] {
        var pairs = Pairs(sizes: sizes, allows: allows)
        for row in rows { pairs.cover(row) }
        var out: [(Int, Int, Int, Int)] = []
        while let p = pairs.firstNeeded() {
            out.append(p)
            pairs.drop(p)
        }
        return out
    }

    /// Which value pairs are still needed, flat: factor pair (a < b) from
    /// `offset[a][b]`, then `va * sizes[b] + vb`.
    struct Pairs {
        let sizes: [Int]
        private var offset: [[Int]]
        private var need: [Bool]
        private var cursor = 0

        init(sizes: [Int], allows: ([Int?]) -> Bool) {
            self.sizes = sizes
            let n = sizes.count
            offset = Array(repeating: Array(repeating: 0, count: n), count: n)
            var total = 0
            for a in 0..<n {
                for b in (a + 1)..<max(n, a + 1) {
                    offset[a][b] = total
                    total += sizes[a] * sizes[b]
                }
            }
            need = Array(repeating: false, count: total)
            var probe = [Int?](repeating: nil, count: n)
            for a in 0..<n {
                for b in (a + 1)..<max(n, a + 1) {
                    for va in 0..<sizes[a] {
                        for vb in 0..<sizes[b] {
                            probe[a] = va
                            probe[b] = vb
                            need[offset[a][b] + va * sizes[b] + vb] = allows(probe)
                        }
                    }
                    probe[b] = nil
                }
                probe[a] = nil
            }
        }

        private func key(_ a: Int, _ va: Int, _ b: Int, _ vb: Int) -> Int {
            a < b ? offset[a][b] + va * sizes[b] + vb : offset[b][a] + vb * sizes[a] + va
        }

        /// New pairs `f = v` would cover beside the factors already set.
        func gain(_ f: Int, _ v: Int, _ row: [Int?]) -> Int {
            var n = 0
            for (g, vg) in row.enumerated() where g != f {
                if let vg, need[key(f, v, g, vg)] { n += 1 }
            }
            return n
        }

        mutating func cover(_ row: [Int]) {
            for a in row.indices {
                for b in row.indices where b > a { need[key(a, row[a], b, row[b])] = false }
            }
        }

        mutating func drop(_ p: (Int, Int, Int, Int)) { need[key(p.0, p.1, p.2, p.3)] = false }

        /// The first needed pair in flat order.
        mutating func firstNeeded() -> (Int, Int, Int, Int)? {
            while cursor < need.count, !need[cursor] { cursor += 1 }
            guard cursor < need.count else { return nil }
            for a in sizes.indices {
                for b in (a + 1)..<max(sizes.count, a + 1) {
                    let start = offset[a][b]
                    if cursor < start + sizes[a] * sizes[b] {
                        let k = cursor - start
                        return (a, k / sizes[b], b, k % sizes[b])
                    }
                }
            }
            return nil
        }
    }
}
