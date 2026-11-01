import Foundation

/// Provider catalog invariants, credential account naming (in-memory, no
/// keychain), and the JSON / JSONL file stores against a temp directory.
@MainActor
enum CatalogAndStorageTests {
    static let suite = TestSuite(name: "Catalog / storage") { t in
        print("[Catalog / storage]")
        catalog(&t)
        credentials(&t)
        storage(&t)
    }

    // MARK: - Provider catalog

    private static func catalog(_ t: inout Checks) {
        let all = AssistantProvider.allCases
        t.equal(ProviderCatalog.all.map(\.id), all, "every provider has a spec, in declaration order")
        t.check(all.allSatisfy { $0.spec.id == $0 }, "spec lookup returns the provider's own spec")
        t.equal(Set(ProviderCatalog.all.map(\.wire)).count, all.count, "wire ids are unique")
        // Persisted ids (UserDefaults, keychain accounts) and wire strings
        // (the Python server) must never drift.
        t.equal(all.map(\.rawValue),
                ["anthropic", "openai", "gemini", "openaiCompatible", "local", "whisper"],
                "persisted raw values unchanged")
        t.equal(all.map(\.wire),
                ["anthropic", "openai", "gemini", "openai_compatible", "local", "whisper"],
                "wire values unchanged")
        t.equal(all.map(\.displayName),
                ["Anthropic (Claude)", "OpenAI", "Google Gemini", "OpenAI-compatible",
                 "Local (on-device)", "Whisper (on-device)"],
                "display names unchanged")
        t.equal(all.map(\.defaultModel),
                ["claude-sonnet-5", "gpt-4o", "gemini-2.5-flash", "", "", "large-v3"],
                "assistant default models unchanged")
        t.equal(all.map(\.keyHint), ["sk-ant-…", "sk-…", "AIza…", "API key", "", ""],
                "key hints unchanged")

        // Capability lookups match the booleans they replaced.
        t.check(all.allSatisfy { $0.needsAPIKey == ($0 != .local && $0 != .whisper) },
                "needsAPIKey: everything but Local and Whisper")
        t.check(all.allSatisfy { $0.isLocal == ($0 == .local) }, "isLocal: Local only")
        t.check(all.allSatisfy { $0.needsBaseURL == ($0 == .openaiCompatible) },
                "needsBaseURL: OpenAI-compatible only")
        t.check(all.allSatisfy { $0.runsOnDevice == ($0 == .local || $0 == .whisper) },
                "on-device pill: Local and Whisper")
        t.equal(AssistantProvider.assistantChoices, all.filter { $0 != .whisper },
                "assistant choices: everything but Whisper")
        t.equal(ProviderCatalog.keyed, [.anthropic, .openai, .gemini, .openaiCompatible],
                "Models page cloud rows, in order")
        t.check(ProviderCatalog.keyed.allSatisfy { !$0.keyHint.isEmpty },
                "every keyed provider has a key hint")
        t.check(all.allSatisfy { $0.has(.listModels) == $0.needsAPIKey },
                "live model lists: the keyed providers (Local re-scans, Whisper has none)")

        // Ground truth: same picker order and presets as before.
        t.equal(GroundTruthSource.singleProviders, [.gemini, .openai, .openaiCompatible, .local, .whisper],
                "ground-truth single providers, in picker order")
        t.equal(all.map(\.groundTruthDefaultModel),
                ["", "gpt-audio", "gemini-2.5-flash", "", "", "large-v3"],
                "ground-truth model presets unchanged")
        t.check(ProviderCatalog.consensusKeyProvider == .openai
                && ProviderCatalog.consensusKeyProvider.needsAPIKey,
                "consensus recipe runs on the OpenAI key")

        // Models page row metadata.
        t.equal(ProviderCatalog.keyed.map { $0.spec.icon },
                ["a.circle.fill", "o.circle.fill", "g.circle.fill",
                 "chevron.left.forwardslash.chevron.right"],
                "provider glyphs unchanged")
        t.equal(ProviderCatalog.keyed.map { $0.spec.keyURL?.absoluteString },
                ["https://console.anthropic.com/settings/keys", "https://platform.openai.com/api-keys",
                 "https://aistudio.google.com/apikey", nil],
                "get-a-key links unchanged")

        var config = AssistantConfig.default
        config.baseURL = "https://example.test/v1"
        t.check(config.baseURL(for: .openaiCompatible) == "https://example.test/v1"
                && config.baseURL(for: .openai).isEmpty,
                "base URL applies to OpenAI-compatible only")
    }

    // MARK: - Credentials

    /// Stand-in secret store: the rules are checked without the keychain.
    private final class MemorySecrets: SecretStore {
        var items: [String: String] = [:]
        func get(_ account: String) -> String? { items[account] }
        func set(_ value: String?, for account: String) -> Bool {
            if let value, !value.isEmpty { items[account] = value } else { items[account] = nil }
            return true
        }
    }

    private static func credentials(_ t: inout Checks) {
        t.equal(AssistantProvider.allCases.map { CredentialStore.account(for: $0) },
                ["provider.anthropic", "provider.openai", "provider.gemini",
                 "provider.openaiCompatible", "provider.local", "provider.whisper"],
                "keychain accounts unchanged (existing keys keep working)")
        t.check(AssistantProvider.allCases.allSatisfy { $0.keychainAccount == CredentialStore.account(for: $0) },
                "provider keychainAccount reads the credential store")
        t.equal(CredentialStore.hfAccount, "provider.huggingface", "HF token account unchanged")

        let secrets = MemorySecrets()
        let store = CredentialStore(secrets: secrets)
        store.setAPIKey("  sk-test\n", for: .openai)
        t.equal(secrets.items["provider.openai"], "sk-test", "keys are trimmed on write")
        secrets.items["provider.gemini"] = "AIza-old\n"
        t.equal(store.apiKey(for: .gemini), "AIza-old", "keys from older builds are trimmed on read")
        t.check(store.hasKey(.openai) && !store.hasKey(.anthropic), "hasKey reflects stored keys")
        store.setAPIKey("   ", for: .openai)
        t.check(secrets.items["provider.openai"] == nil && !store.hasKey(.openai),
                "a blank key clears the slot")
        store.setHuggingFaceToken(" hf_abc\n")
        t.equal(store.huggingFaceToken, "hf_abc", "HF token trimmed, in its own slot")
    }

    // MARK: - File stores

    private struct Row: Codable, Equatable {
        let id: String
        let at: Date
    }

    private static func storage(_ t: inout Checks) {
        t.check(AppSupport.historyFile.path.hasSuffix("/Application Support/Slive/history.json")
                && AppSupport.trainingDirectory.path.hasSuffix("/Application Support/Slive/training"),
                "app support paths unchanged")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("slive-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func names() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [Row(id: "a", at: now), Row(id: "b", at: now.addingTimeInterval(60))]

        // JSONFileStore: missing → ok round-trip → corrupt moved aside.
        let json = JSONFileStore<[Row]>(url: dir.appendingPathComponent("history.json"), label: "selftest")
        if case .missing = json.load() { t.check(true, "json: no file loads as missing") }
        else { t.check(false, "json: no file loads as missing") }
        try? json.save(rows)
        if case .ok(let back) = json.load() { t.equal(back, rows, "json: save → load round-trips") }
        else { t.check(false, "json: save → load round-trips") }
        try? Data("{not json".utf8).write(to: json.url)
        if case .corrupt(let movedTo) = json.load(now: now) {
            t.equal(movedTo?.lastPathComponent, "history.json.corrupt-1700000000",
                    "json: corrupt file moved aside under the pinned name")
            t.check(!fm.fileExists(atPath: json.url.path)
                    && (movedTo.flatMap { try? Data(contentsOf: $0) }) == Data("{not json".utf8),
                    "json: original bytes kept, live file cleared")
        } else {
            t.check(false, "json: corrupt file moved aside under the pinned name")
        }
        // Backup expiry: only those set aside before the cutoff go.
        try? Data().write(to: CorruptBackup.url(for: json.url, at: now.addingTimeInterval(-90_000)))
        CorruptBackup.remove(of: json.url, olderThan: now.addingTimeInterval(-86_400))
        t.equal(names().filter { $0.hasPrefix("history.json.corrupt-") }, ["history.json.corrupt-1700000000"],
                "json: expired backups pruned, fresh ones kept")

        // JSONLFileStore: append, torn-line guard, parse counting, backup once.
        let jsonl = JSONLFileStore<Row>(url: dir.appendingPathComponent("samples.jsonl"), label: "selftest index")
        let first = (try? jsonl.append(rows[0])) ?? 0
        t.check(first > 0, "jsonl: first append creates the file")
        if let h = try? FileHandle(forWritingTo: jsonl.url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data("{\"id\":\"torn\",\"at\":".utf8))   // crash mid-append
            try? h.close()
        }
        _ = try? jsonl.append(rows[1])
        let parsed = JSONLFileStore<Row>.parse((try? Data(contentsOf: jsonl.url)) ?? Data())
        t.check(parsed.elements == rows && parsed.undecodable == 1,
                "jsonl: torn line costs only itself; the next append still decodes",
                "\(parsed.elements.count) good, \(parsed.undecodable) bad")
        t.equal(jsonl.load(now: now), rows, "jsonl: load returns the decodable rows")
        _ = jsonl.load(now: now.addingTimeInterval(5))
        t.equal(names().filter { $0.hasPrefix("samples.jsonl.corrupt-") }, ["samples.jsonl.corrupt-1700000000"],
                "jsonl: unreadable lines copied aside once, not per launch")
        let written = (try? jsonl.rewrite(rows)) ?? 0
        // FileManager, not URL.resourceValues: that caches per URL until a
        // run-loop turn, which the self-test never takes.
        let size = (try? fm.attributesOfItem(atPath: jsonl.url.path)[.size] as? Int64) ?? -1
        t.check(written == size && JSONLFileStore<Row>.parse((try? Data(contentsOf: jsonl.url)) ?? Data()).undecodable == 0,
                "jsonl: rewrite replaces the file and reports its size")
        jsonl.removeAll()
        t.check(!names().contains { $0.hasPrefix("samples.jsonl") },
                "jsonl: clear removes the index and its backups")
    }
}
