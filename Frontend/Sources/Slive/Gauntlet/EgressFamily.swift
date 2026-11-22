import AppKit
import Foundation
import SliveReport

// G4 — egress, cost and privacy.
//
// Sessions: dictate through the app's real recording path (AppRecords →
// TrainingStore → LabelRun → GroundTruthClient → LocalServer) from a fresh
// install and from every upgrade fixture, with and without an OpenAI key, with
// the server's transport replaced by a recorder. Money and audio leave only on
// a user's explicit yes.
//
// Privacy fuzz: PII-shaped strings planted in settings, history, log lines and
// error text; a problem report is built the way the reporter builds one; none
// of it may appear.

/// Every request `LocalServer` would have sent, in order. Locked: requests are
/// made off the main actor.
final class EgressRecorder: @unchecked Sendable {
    struct Request { let method: String; let path: String }
    private let lock = NSLock()
    private var recorded: [Request] = []

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Request(method: request.httpMethod ?? "GET", path: request.url?.path ?? "?"))
    }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    var paths: [String] { requests.map(\.path) }

    /// The canned reply the app's decoders accept, so a recorded request
    /// completes as it would against the real server.
    static func reply(for request: URLRequest) -> (Data, URLResponse) {
        let url = request.url ?? ServerConfig.url("/")
        let body: String
        switch url.path {
        case "/label_consensus":
            body = #"{"text":"hello there my friend","chosen":"gpt-transcribe","agreement":0.95,"unconfirmed":[],"candidates":{},"prompt":"p"}"#
        case "/label_format":
            body = #"{"formatted":"Hello there, my friend.","status":"formatted","model":"gpt-5.5"}"#
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// What one scripted session is made of.
struct EgressSession {
    let name: String
    let stored: [String: Any]
    /// An OpenAI key is saved (the only thing that lets a label be paid for).
    let hasKey: Bool
    /// The user explicitly turned automatic labeling on in this fixture.
    var optedIn: Bool { (stored["autoLabelNew"] as? Bool) == true }
}

@MainActor enum EgressFamily {
    static let family = GauntletFamily(name: "egress", seeded: true) { EgressFamily.run(&$0) }

    /// Routes whose use costs money or sends audio, text or keys to a cloud
    /// service (the Python server forwards them upstream).
    static let cloudPaths: Set<String> = ["/assistant", "/assistant/stream", "/transcribe_llm",
                                           "/label_consensus", "/label_format", "/models", "/local/download"]
    static let labelingPaths: Set<String> = ["/transcribe_llm", "/label_consensus", "/label_format"]

    static func run(_ run: inout GauntletRun) {
        let recorder = EgressRecorder()
        LocalServer.transport = { request in
            recorder.record(request)
            return EgressRecorder.reply(for: request)
        }
        defer { LocalServer.transport = nil }

        sessions(&run, recorder: recorder)
        privacy(&run)
    }

    // MARK: - Scripted sessions

    private static func fixtureSessions() -> [EgressSession] {
        var out: [EgressSession] = []
        for version in UpgradeFamily.versions {
            guard let file = GauntletFixtureFiles.json("prefs/\(version).json"),
                  let profiles = file["profiles"] as? [[String: Any]] else { continue }
            for raw in profiles {
                guard let name = raw["name"] as? String, let stored = raw["stored"] as? [String: Any] else { continue }
                for key in [false, true] {
                    out.append(EgressSession(name: "\(version) \(name)",
                                             stored: UpgradeProfile.storedValues(stored), hasKey: key))
                }
            }
        }
        return out
    }

    /// Dictate twice in a session; the cloud paths it reached (every path, in order).
    private static func dictate(_ session: EgressSession, recorder: EgressRecorder,
                                explicitLabelAll: Bool = false) -> [String] {
        let before = recorder.requests.count
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("slive-gauntlet-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let settings = Settings(store: InMemoryStore(session.stored), loginItemEnabled: { false })
        let secrets = CountingSecrets()
        if session.hasKey { secrets.values[CredentialStore.account(for: .openai)] = "sk-gauntlet-fixture-key" }
        let providers = ProviderStore(settings: settings, credentials: CredentialStore(secrets: secrets),
                                      scanLocalCache: { [] })
        let store = TrainingStore(root: temp.appendingPathComponent("training"),
                                  captureMaxGB: { settings.captureMaxGB })
        let labels = LabelRun(store: store, settings: settings, providers: providers)
        let records = AppRecords(settings: settings, capabilities: Capabilities(hasServer: true),
                                 training: store, labels: labels)

        let clip = temp.appendingPathComponent("clip.wav")
        try? silentWAV(seconds: 0.5).write(to: clip)
        records.addTrainingPair("hello there my friend", audioURL: clip)
        records.addTrainingPair("see you at the meeting tomorrow", audioURL: clip)
        settle(labels)
        if explicitLabelAll {
            labels.labelEverything()
            settle(labels)
        }
        return Array(recorder.paths.dropFirst(before))
    }

    /// Let the label run's tasks finish. Iteration-bounded, not time-bounded:
    /// idle means a stretch of run-loop turns with no run in flight.
    private static func settle(_ labels: LabelRun) {
        var idle = 0, turns = 0
        while idle < 40 && turns < 2_000_000 {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.0005))
            turns += 1
            idle = labels.isRunning ? 0 : idle + 1
        }
    }

    /// A 16 kHz mono PCM16 WAV of silence — long enough for the label run's
    /// "too short" gate, with no microphone involved.
    static func silentWAV(seconds: Double) -> Data {
        let samples = Int(16_000 * seconds)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    private static func sessions(_ run: inout GauntletRun, recorder: EgressRecorder) {
        let fresh = [false, true].map { EgressSession(name: "fresh install", stored: [:], hasKey: $0) }
        let upgrades = fixtureSessions()

        var cloudWithoutConsent: [String] = []   // any session that paid or sent without a yes
        var upgradeOffenders: [String] = []
        var anyRequest: [String] = []
        for session in fresh + upgrades {
            // A user who switched labeling on has said yes; the controls below cover them.
            if session.optedIn { continue }
            let paths = dictate(session, recorder: recorder)
            let label = "\(session.name)\(session.hasKey ? " +key" : "")"
            if !paths.isEmpty { anyRequest.append("\(label): \(paths.joined(separator: ","))") }
            if paths.contains(where: cloudPaths.contains) {
                cloudWithoutConsent.append("\(label): \(paths.filter(cloudPaths.contains).joined(separator: ","))")
                if session.name != "fresh install" { upgradeOffenders.append(label) }
            }
        }
        run.check(cloudWithoutConsent.isEmpty, id: "P-NO-PAID-WITHOUT-CONSENT",
                  "dictating from a fresh install and from every release's prefs, key saved or not, reaches no paid or cloud endpoint",
                  cloudWithoutConsent.prefix(6).joined(separator: " | "))
        run.check(upgradeOffenders.isEmpty, id: "F1",
                  "an upgrade with an OpenAI key saved doesn't start labeling dictations in the cloud",
                  upgradeOffenders.prefix(6).joined(separator: " | "))
        run.check(anyRequest.isEmpty, id: "egress.dictation-is-offline",
                  "dictating without a yes sends no request to the server at all",
                  anyRequest.prefix(6).joined(separator: " | "))

        // Controls: the recorder does see a label when the user said yes, and
        // a yes without a key still can't pay.
        let optedIn = upgrades.filter { $0.optedIn }
        let withKey = optedIn.filter(\.hasKey)
        let labeled = withKey.map { dictate($0, recorder: recorder) }
        run.check(!withKey.isEmpty && labeled.allSatisfy { $0.contains("/label_consensus") && $0.contains("/label_format") },
                  id: "egress.recorder-sees-consent",
                  "automatic labeling the user switched on (0.2.5 and 0.2.6) does reach the labeling endpoints",
                  "\(withKey.count) sessions, requests: \(labeled.map { $0.joined(separator: ",") })")
        let keyless = optedIn.filter { !$0.hasKey }.map { dictate($0, recorder: recorder) }
        run.check(!keyless.isEmpty && keyless.allSatisfy(\.isEmpty), id: "P-NO-PAID-WITHOUT-CONSENT",
                  "a yes without an OpenAI key sends nothing",
                  keyless.map { $0.joined(separator: ",") }.joined(separator: " | "))

        let explicit = EgressSession(name: "untouched click", stored: [:], hasKey: true)
        let clicked = dictate(explicit, recorder: recorder, explicitLabelAll: true)
        run.check(clicked.contains("/label_consensus"), id: "egress.recorder-sees-consent",
                  "clicking Label everything with a key labels (the explicit action is what pays)",
                  clicked.joined(separator: ","))
        let clickedNoKey = dictate(EgressSession(name: "untouched click", stored: [:], hasKey: false),
                                   recorder: recorder, explicitLabelAll: true)
        run.check(clickedNoKey.isEmpty, id: "P-NO-PAID-WITHOUT-CONSENT",
                  "clicking Label everything without a key sends nothing", clickedNoKey.joined(separator: ","))
    }

    // MARK: - Privacy fuzz

    nonisolated fileprivate static let givenNames = ["Priyanka", "Tobiasz", "Oluwaseun", "Anneliese", "Zbigniew", "Marguerite",
                                     "Thandiwe", "Casimir", "Ingeborg", "Ravindra", "Wilhelmina", "Evangelos"]
    nonisolated fileprivate static let surnames = ["Kowalczyk", "Adebayo", "Lindqvist", "Fernandes", "Okonkwo", "Hartmann",
                                   "Venkataraman", "Castellanos", "Svensson", "Abernathy", "Nakamura", "Delacroix"]
    /// Words nobody writes in a bug report: if one shows up, dictated text leaked.
    nonisolated fileprivate static let rareWords = ["quillon", "marzipan", "vexillum", "gadroon", "sphagnum", "tamarind",
                                    "obsidian", "perihelion", "cumulonimbus", "bergamot", "fibonacci", "zeppelin",
                                    "mandolin", "ptarmigan", "chiaroscuro", "saffron", "kaleidoscope", "burdock"]

    struct Persona {
        let user: String, fullName: String, other: String
        let email: String, otherEmail: String
        let secrets: [String]
        let dictated: [String]
        let device: String, host: String

        init(_ rng: inout SeededRandom) {
            func pick(_ list: [String]) -> String { list[Int(rng.next() % UInt64(list.count))] }
            func token(_ n: Int, _ alphabet: String) -> String {
                let chars = Array(alphabet)
                return String((0..<n).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
            }
            let alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            let first = pick(EgressFamily.givenNames), last = pick(EgressFamily.surnames)
            fullName = "\(first) \(last)"
            user = (first + String(last.prefix(2))).lowercased()
            other = pick(EgressFamily.surnames).lowercased() + token(2, "0123456789")
            email = "\(first.lowercased()).\(last.lowercased())@\(pick(["example.com", "mail.example.org", "corp.example.net"]))"
            otherEmail = "\(other)@example.com"
            secrets = ["sk-" + token(48, alnum),
                       "sk-ant-api03-" + token(90, alnum + "_-"),
                       "sk-proj-" + token(60, alnum + "_-"),
                       "AIza" + token(35, alnum + "_-"),
                       "hf_" + token(34, alnum),
                       "gsk_" + token(52, alnum)]
            var words = EgressFamily.rareWords
            dictated = (0..<5).map { _ in words.remove(at: Int(rng.next() % UInt64(words.count))) }
            device = "\(first)’s AirPods Pro"
            host = "\(first)s-MacBook-Air.local"
        }

        /// Everything that must not come out, with what it is.
        var forbidden: [(String, String)] {
            var out: [(String, String)] = [("user name", user), ("other user", other), ("email", email),
                                           ("other email", otherEmail), ("device", device)]
            for part in fullName.split(separator: " ") { out.append(("name", String(part))) }
            for key in secrets { out.append(("key", key)); out.append(("key tail", String(key.suffix(20)))) }
            for word in dictated { out.append(("dictated word", word)) }
            return out
        }
    }

    /// What of the persona's data shows anywhere a person could read it: the
    /// issue title and body, and the prefilled GitHub link, decoded.
    private static func leaks(_ report: ProblemReport, _ persona: Persona) -> [String] {
        let decodedURL = report.issueURL().absoluteString.removingPercentEncoding ?? ""
        let text = (report.title + "\n" + report.markdown() + "\n" + decodedURL).lowercased()
        return persona.forbidden.filter { text.contains($0.1.lowercased()) }
            .map { "\($0.0) “\($0.1.prefix(24))”" }
    }

    private static func privacy(_ run: inout GauntletRun) {
        var found: [String] = []
        for seed in run.seeds {
            var rng = SeededRandom(seed: seed &* 0x9E37_79B9 &+ 4)
            let persona = Persona(&rng)
            let (report, planted) = problemReport(persona, seed: seed, rng: &rng)
            let leaked = leaks(report, persona)
            guard !leaked.isEmpty else { continue }
            found += leaked.map { "seed \(seed): \($0)" }
            if found.count <= 3 {
                run.regression(family: "egress", seed: seed, script: planted.joined(separator: "\n"))
            }
        }
        run.check(found.isEmpty, id: "P-NOTHING-PERSONAL-LEAVES",
                  "a problem report built from planted emails, /Users paths, API keys, device names and dictated text carries none of them (\(run.seeds.count) seeds)",
                  found.prefix(6).joined(separator: " | "))

        // The detector must see a leak when there is one: the same report with
        // its log lines left unredacted.
        if let seed = run.seeds.first {
            var rng = SeededRandom(seed: seed &* 0x9E37_79B9 &+ 4)
            let persona = Persona(&rng)
            var (report, _) = problemReport(persona, seed: seed, rng: &rng)
            report.appLog = ["mail \(persona.email) key \(persona.secrets[0]) said “\(persona.dictated[0])”"]
            report.serverLog = []
            report.details = ["/Users/\(persona.user)/Library"]
            run.check(leaks(report, persona).count >= 3, id: "egress.privacy-detector",
                      "the leak detector flags an unredacted report")
        }
    }

    /// The report the reporter would build for a failure, from settings,
    /// history and log lines that all carry the persona's data. Mirrors
    /// ReporterController: context through `clean`, log and error text through
    /// `cleanFreeText`, server lines through `Collectors.serverLine`.
    private static func problemReport(_ p: Persona, seed: UInt64, rng: inout SeededRandom)
        -> (ProblemReport, [String]) {
        func pick<T>(_ list: [T]) -> T { list[Int(rng.next() % UInt64(list.count))] }
        let redactor = Redactor(userName: p.user, fullName: p.fullName, homeDirectory: "/Users/\(p.user)",
                                hostNames: [p.host, p.host.replacingOccurrences(of: ".local", with: "")],
                                deviceNames: [p.device])
        let sentence = p.dictated.joined(separator: " ")
        func key() -> String { pick(p.secrets) }
        var planted: [String] = []

        // Settings holding personal values.
        let store = InMemoryStore()
        let settings = Settings(store: store, loginItemEnabled: { false })
        settings.hotwords = "\(p.fullName), \(p.email), \(p.dictated[0])"
        settings.contextPrompt = "I work from /Users/\(p.user)/Code/\(p.dictated[1]) on \(sentence)"
        settings.inputDeviceName = p.device
        settings.inputDeviceUID = "BluetoothDevice-AA-BB-CC-DD-EE-FF:input"
        settings.groundTruthBaseURL = "https://\(p.host)/v1?key=\(key())"
        settings.consensusPrompt = "Speaker \(p.fullName) \(p.email) \(sentence)"
        settings.whisperModel = "\(p.user)-voice-ft"
        var config = settings.assistantConfig
        config.baseURL = "https://corp.example.net/v1?token=\(key())"
        config.systemPrompt = "Reply to \(p.email) about \(sentence)"
        config.fetchedModels["openai"] = ["\(p.user)-model"]
        settings.assistantConfig = config
        planted.append("settings: hotwords, context, device, base URLs, prompts, model named \(p.user)-voice-ft")
        let context = FailureReporter.context(settings: settings) { _ in "ready" }
            .mapValues { redactor.clean($0) }

        // History holding dictated text.
        let history = HistoryStore(fileURL: nil)
        history.add(sentence)
        history.add("mail \(p.email) the \(p.dictated[2]) from /Users/\(p.other)/Desktop")
        let remembered = history.syncedEntries().count
        planted.append("history: \(remembered) dictated entries")

        // Log lines and error text, as they would be read back.
        let quote = pick([("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»")])
        let lines = [
            "decoded in 0.31s (\(p.user)-voice-ft, 54 chars)",
            "typed into /Users/\(p.user)/Library/Application Support/Slive/history.json",
            "opened \(p.device) at \(p.host)",
            "mail to \(p.email) and \(p.otherEmail)",
            "request failed: Authorization: Bearer \(key())",
            "POST https://api.openai.com/v1/audio/transcriptions?api_key=\(key())",
            "config api_key=\(key()) base https://\(p.host)/v1",
            "provider said \(quote.0)\(sentence)\(quote.1)",
            "file /Users/\(p.other)/Code/server.swift:\(Int(rng.next() % 900) + 1)",
            "key \(key())",
        ]
        planted += lines
        let log = lines.map { String(redactor.cleanFreeText($0).prefix(240)) }
        let serverLines = [
            "  File \"/Users/\(p.user)/.slive/Slive/Backend/src/flowy/server.py\", line 120, in label",
            "httpx.HTTPStatusError: Client error '401' for url 'https://api.openai.com/v1/x?key=\(key())'",
            "ValueError: bad input \(quote.0)\(sentence)\(quote.1) for \(p.email)",
            "INFO: 127.0.0.1 - \"POST /label_consensus HTTP/1.1\" 200",
        ].compactMap { Collectors.serverLine($0, redactor: redactor) }
        planted += serverLines

        let error = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSLocalizedDescriptionKey: "The file “\(p.dictated[4]).wav” couldn’t be opened at /Users/\(p.user)/x for \(p.email).",
            NSFilePathErrorKey: "/Users/\(p.user)/Library/x"])
        let detail = redactor.cleanFreeText("\(error.domain) \(error.code): \(error.localizedDescription) · POST /label_consensus")

        let report = ProblemReport(
            kind: .failure,
            headline: redactor.clean("The Slive Server hit an error."),
            summary: redactor.clean("The Slive Server hit an error.") + " (server)",
            details: [detail],
            failurePoint: ["caught at " + redactor.clean("LocalServer.swift:90 send(_:file:line:function:)")],
            build: BuildInfo(version: "0.2.6", edition: "Full", commit: "abc1234", commitDate: nil),
            system: SystemInfo(macOS: "26.1", chip: "Apple M4", memoryGB: 16),
            context: context, appUptime: 120, appLog: log, serverLog: serverLines)
        return (report, planted)
    }
}
