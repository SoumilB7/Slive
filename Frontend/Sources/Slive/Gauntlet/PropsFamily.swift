import CoreGraphics
import Foundation

// G7 — text and data properties. Seeded generators over the pure pieces that
// handle the user's words and files: the vocabulary pass, the live-typing
// stitcher, the JSON stores and the shortcut recorder. Each property is
// phrased as what must hold for ANY input, so a fix can't be "special-cased"
// around the one example a review found.

@MainActor enum PropsFamily {
    static let family = GauntletFamily(name: "props", seeded: true) { PropsFamily.run(&$0) }

    static func run(_ run: inout GauntletRun) {
        vocabulary(&run)
        stitching(&run)
        stores(&run)
        recorder(&run)
    }

    // MARK: - Helpers

    private static func pick<T>(_ list: [T], _ rng: inout SeededRandom) -> T {
        list[Int(rng.next() % UInt64(list.count))]
    }

    private static func shuffled<T>(_ list: [T], _ rng: inout SeededRandom) -> [T] {
        var out = list
        for i in stride(from: out.count - 1, to: 0, by: -1) { out.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        return out
    }

    /// About 400 of the most common English words, lower case.
    static let commonWords: [String] = """
        the be to of and a in that have i it for not on with he as you do at this but his by from they
        we say her she or an will my one all would there their what so up out if about who get which go
        me when make can like time no just him know take people into year your good some could them see
        other than then now look only come its over think also back after use two how our work first
        well way even new want because any these give day most us is are was were been has had did said
        each tell does set three need feel put mean keep let begin seem help talk turn start show hear
        play run move live believe hold bring happen write provide sit stand lose pay meet include
        continue learn change lead understand watch follow stop create speak read allow add spend grow
        open walk win offer remember love consider appear buy wait serve die send expect build stay fall
        cut reach kill remain suggest raise pass sell require report decide pull ask home man woman
        child world life hand part place case week company system program question government number
        night point room mother area money story fact month lot right study book eye job word business
        issue side kind head house service friend father power hour game line end member law car city
        community name president team minute idea body information parent face others level office door
        health person art war history party result morning reason research girl guy moment air teacher
        force education foot boy age policy music market sense nation plan college interest death
        experience effect class control care field development role effort rate heart drug leader light
        voice wife police mind price decision son view relationship town road arm difference value
        building action model season society tax director position player record paper space ground form
        event official matter center couple site project activity star table court oil situation cost
        industry figure street image phone data picture practice piece land product doctor wall patient
        worker news test movie north support technology step baby computer type attention film tree
        source organization hair window culture chance brother energy period course summer plant net ok
        big small long little great high low early late young old same different important large able
        sure free full clear ready simple hard easy fast slow quiet loud warm cold dark bright
""".split(whereSeparator: \.isWhitespace).map(String.init)

    // MARK: - VocabularyCorrector (F12)

    /// Short vocabulary entries people really add that are ALSO ordinary
    /// words or letters: IT, US, Go, .NET (net), OK, AM, OR, IN, ME.
    static let collidingTerms = ["IT", "US", "AI", "Go", "C#", ".NET", "OK", "ID", "PM", "AM", "OR", "IN", "ME"]
    static let collidingWords = ["it", "us", "go", "net", "ok", "am", "or", "in", "me", "id", "pm"]

    private static func vocabulary(_ run: inout GauntletRun) {
        var rewrites = Set<String>()
        var runs = 0
        for seed in run.seeds {
            var rng = SeededRandom(seed: seed &+ 0x1001)
            var words = (0..<3).map { _ in pick(collidingWords, &rng) }
            words += (0..<(6 + Int(rng.next() % 6))).map { _ in pick(commonWords, &rng) }
            words = shuffled(words, &rng)
            words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
            if words.count > 4 { words[3] += "," }
            let sentence = words.joined(separator: " ") + "."
            for term in collidingTerms {
                runs += 1
                let out = VocabularyCorrector.correct(sentence, hotwords: term)
                guard out != sentence else { continue }
                let before = sentence.split(separator: " "), after = out.split(separator: " ")
                if let i = (0..<min(before.count, after.count)).first(where: { before[$0] != after[$0] }) {
                    rewrites.insert("\(term): “\(before[i])” → “\(after[i])”")
                } else {
                    rewrites.insert("\(term): “\(sentence.prefix(30))” → “\(out.prefix(30))”")
                }
            }
        }
        run.check(rewrites.isEmpty, id: "F12",
                  "short vocabulary terms (IT, US, Go, .NET, …) never rewrite a common English word (\(runs) sentences × terms)",
                  rewrites.sorted().prefix(8).joined(separator: " | "))
    }

    // MARK: - stitchTranscripts

    static let han = Array(Set("的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工话儿者向情部正名定女问力机给等几很商")).sorted().map(String.init)
    static let thai = Array("กขคฆงจฉชซญดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ").map(String.init)

    private static func stitching(_ run: inout GauntletRun) {
        var latinBad: [String] = [], hanBad: [String] = [], thaiBad: [String] = []
        for seed in run.seeds {
            var rng = SeededRandom(seed: seed &+ 0x2002)
            // Latin: words, with the overlap re-cased and re-punctuated in the tail.
            let words = Array(shuffled(commonWords, &rng).prefix(8 + Int(rng.next() % 13)))
            let k = 1 + Int(rng.next() % UInt64(min(6, words.count / 2 - 1)))
            let m = k + 1 + Int(rng.next() % UInt64(words.count - k - 1))
            let confirmed = words[0..<m].joined(separator: " ")
            var tail = Array(words[(m - k)...])
            for i in 0..<k {
                switch rng.next() % 3 {
                case 0: tail[i] = tail[i].capitalized
                case 1: tail[i] += "."
                default: break
                }
            }
            let latinExpected = words.joined(separator: " ")
            let latinGot = ContinuousDictation.stitchTranscripts(confirmed: confirmed, tail: tail.joined(separator: " "))
            if latinGot != latinExpected {
                latinBad.append("seed \(seed)")
                if latinBad.count <= 2 {
                    run.regression(family: "props", seed: seed, script:
                        "confirmed “\(confirmed)”\ntail      “\(tail.joined(separator: " "))”\ngot       “\(latinGot)”")
                }
            }
            // Scripts written without spaces: one unbroken run per side.
            for (pool, name) in [(han, "han"), (thai, "thai")] {
                let chars = Array(shuffled(pool, &rng).prefix(10 + Int(rng.next() % 15)))
                let k = 2 + Int(rng.next() % 5)
                let m = k + 1 + Int(rng.next() % UInt64(chars.count - k - 1))
                let confirmed = chars[0..<m].joined()
                let tail = chars[(m - k)...].joined()
                let got = ContinuousDictation.stitchTranscripts(confirmed: confirmed, tail: tail)
                if got != chars.joined() {
                    if name == "han" { hanBad.append("seed \(seed)") } else { thaiBad.append("seed \(seed)") }
                    if hanBad.count + thaiBad.count <= 2 {
                        run.regression(family: "props", seed: seed, script:
                            "\(name): confirmed “\(confirmed)”\ntail “\(tail)”\ngot  “\(got)”")
                    }
                }
            }
        }
        let seeds = run.seeds.count
        run.check(latinBad.isEmpty, id: "props.stitch-latin",
                  "a tail that repeats the end of the confirmed text never duplicates it in Latin text (\(seeds) seeds)",
                  latinBad.prefix(4).joined(separator: ", "))
        run.check(hanBad.isEmpty, id: "props.stitch-cjk",
                  "…and never in Chinese text, which has no spaces (\(seeds) seeds)", "\(hanBad.count) seeds duplicate the seam, e.g. \(hanBad.prefix(3).joined(separator: ", "))")
        run.check(thaiBad.isEmpty, id: "props.stitch-cjk",
                  "…and never in Thai text (\(seeds) seeds)", "\(thaiBad.count) seeds duplicate the seam, e.g. \(thaiBad.prefix(3).joined(separator: ", "))")
    }

    // MARK: - JSON stores

    /// A damaged copy of `data`: torn, bit-flipped, zeroed, cut or padded.
    static func damage(_ data: Data, _ rng: inout SeededRandom) -> Data {
        guard !data.isEmpty else { return data }
        var bytes = [UInt8](data)
        func at() -> Int { Int(rng.next() % UInt64(bytes.count)) }
        switch rng.next() % 6 {
        case 0: bytes = Array(bytes.prefix(at()))                            // torn write
        case 1: for _ in 0..<(1 + Int(rng.next() % 4)) { bytes[at()] ^= 1 << UInt8(rng.next() % 8) }
        case 2: for _ in 0..<(1 + Int(rng.next() % 3)) { bytes[at()] = rng.next() % 2 == 0 ? 0xFF : 0x00 }
        case 3:
            let from = at(), len = min(bytes.count - from, 1 + Int(rng.next() % 40))
            bytes.removeSubrange(from..<(from + len))                          // a lost chunk
        case 4:
            let from = at()
            bytes.insert(contentsOf: (0..<(1 + Int(rng.next() % 12))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: from)
        default:
            let from = at(), len = min(bytes.count - from, 1 + Int(rng.next() % 30))
            for i in from..<(from + len) { bytes[i] = 0 }                      // a zeroed block
        }
        return Data(bytes)
    }

    private static func backups(of file: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(),
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(CorruptBackup.prefix(for: file)) }
    }

    private static func stores(_ run: inout GauntletRun) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slive-gauntlet-props-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        var historyBad: [String] = [], oneBadDropsGood: [String] = [], indexBad: [String] = []
        for seed in run.seeds {
            var rng = SeededRandom(seed: seed &+ 0x3003)
            let dir = root.appendingPathComponent("s\(seed)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // History (JSONFileStore): damage the file, reopen.
            let file = dir.appendingPathComponent("history.json")
            let seedStore = HistoryStore(fileURL: file)
            let count = 2 + Int(rng.next() % 8)
            for i in 0..<count { seedStore.add("entry \(i) \(pick(commonWords, &rng)) \(pick(commonWords, &rng))") }
            let written = seedStore.syncedEntries()
            guard let original = try? Data(contentsOf: file), written.count == count else {
                historyBad.append("seed \(seed): fixture history wasn't written"); continue
            }
            let torn = damage(original, &rng)
            try? torn.write(to: file)
            let reopened = HistoryStore(fileURL: file)
            let kept = reopened.syncedEntries()
            var decodable = (try? decoder.decode([HistoryEntry].self, from: torn)) ?? []
            let readable = (try? decoder.decode([HistoryEntry].self, from: torn)) != nil
            HistoryStore.applyBounds(&decodable)
            let savedCopy = backups(of: file).contains { (try? Data(contentsOf: $0)) == torn }
            if readable ? kept.count < decodable.count : !savedCopy {
                historyBad.append("seed \(seed): \(readable ? "dropped readable entries" : "unreadable file and no backup")")
            }
            reopened.add("after the damage")
            _ = reopened.syncedEntries()
            if !readable, !backups(of: file).contains(where: { (try? Data(contentsOf: $0)) == torn }) {
                historyBad.append("seed \(seed): the next save destroyed the backup")
            }

            // One bad entry among good ones: the good ones are the user's history.
            let oneFile = dir.appendingPathComponent("one.json")
            let one = HistoryStore(fileURL: oneFile)
            for i in 0..<count { one.add("good \(i) \(pick(commonWords, &rng))") }
            let ids = one.syncedEntries().map { $0.id.uuidString }
            if let data = try? Data(contentsOf: oneFile),
               var list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], list.count == count {
                let victim = Int(rng.next() % UInt64(list.count))
                let gone = list[victim]["id"] as? String
                switch rng.next() % 4 {
                case 0: list[victim]["text"] = 123
                case 1: list[victim].removeValue(forKey: "id")
                case 2: list[victim]["id"] = "not-a-uuid"
                default: list[victim]["createdAt"] = "yesterday"
                }
                try? JSONSerialization.data(withJSONObject: list).write(to: oneFile)
                let survivors = Set(HistoryStore(fileURL: oneFile).syncedEntries().map { $0.id.uuidString })
                let lost = ids.filter { $0 != gone && !survivors.contains($0) }
                if !lost.isEmpty { oneBadDropsGood.append("seed \(seed): \(lost.count) of \(count - 1) good entries lost") }
            }

            // Training index (JSONLFileStore): a bad line costs only itself.
            let index = JSONLFileStore<EditSample>(url: dir.appendingPathComponent("samples.jsonl"), label: "training index")
            let lineCount = 3 + Int(rng.next() % 8)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var lines: [Data] = [], sampleIDs: [String] = []
            for i in 0..<lineCount {
                let id = "s\(seed)-\(i)"
                let sample = EditSample(id: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                                        app: nil, transcript: "hello \(pick(commonWords, &rng))", finalText: "",
                                        edited: false, confidence: "audio", audioFile: "audio/\(id).wav",
                                        llmTranscript: nil, llmModel: nil)
                if let line = try? encoder.encode(sample) { lines.append(line); sampleIDs.append(id) }
            }
            var blob = Data()
            for line in lines { blob.append(line); blob.append(0x0A) }
            let damaged = damage(blob, &rng)
            try? damaged.write(to: index.url)
            let untouched = Set(damaged.split(separator: 0x0A).map { Data($0) })
            let mustKeep = zip(lines, sampleIDs).filter { untouched.contains($0.0) }.map(\.1)
            let loaded = Set(index.load().map(\.id))
            let hadBad = JSONLFileStore<EditSample>.parse(damaged).undecodable > 0
            let lostLines = mustKeep.filter { !loaded.contains($0) }
            if !lostLines.isEmpty { indexBad.append("seed \(seed): lost \(lostLines.count) untouched lines") }
            if hadBad, backups(of: index.url).isEmpty { indexBad.append("seed \(seed): unreadable lines, no backup") }
        }
        let seeds = run.seeds.count
        run.check(historyBad.isEmpty, id: "props.store",
                  "a torn or bit-flipped history file loads without crashing; it keeps what decodes or is set aside, and the next save keeps the backup (\(seeds) seeds)",
                  historyBad.prefix(4).joined(separator: " | "))
        run.check(oneBadDropsGood.isEmpty, id: "F22",
                  "one bad history entry doesn't cost the good ones",
                  "\(oneBadDropsGood.count) seeds, e.g. \(oneBadDropsGood.prefix(2).joined(separator: " | "))")
        run.check(indexBad.isEmpty, id: "props.store",
                  "a damaged training index keeps every untouched line and copies the damaged file aside (\(seeds) seeds)",
                  indexBad.prefix(4).joined(separator: " | "))
    }

    // MARK: - Shortcut recorder (F13)

    private static let cmd: UInt64 = 0x100000, shift: UInt64 = 0x20000, ctrl: UInt64 = 0x40000
    private static let opt: UInt64 = 0x80000, fn: UInt64 = 0x800000

    /// What macOS and every app already do with these presses, written out
    /// by hand (US key codes) — not derived from the recorder's own table.
    private static let systemShortcuts: [(String, UInt16, UInt64, String?)] = [
        ("⌘C", 8, cmd, "c"), ("⌘V", 9, cmd, "v"), ("⌘X", 7, cmd, "x"), ("⌘Z", 6, cmd, "z"),
        ("⌘A", 0, cmd, "a"), ("⌘Q", 12, cmd, "q"), ("⌘W", 13, cmd, "w"), ("⌘H", 4, cmd, "h"),
        ("⌘M", 46, cmd, "m"), ("⌘Tab", 48, cmd, nil), ("⌘Space", 49, cmd, nil), ("⌃Space", 49, ctrl, nil),
        ("⌘⇧3", 20, cmd | shift, "3"), ("⌘⇧4", 21, cmd | shift, "4"), ("⌘⇧5", 23, cmd | shift, "5"),
        // The same keys on a layout whose letters aren't ASCII (Russian: с, м, ч…).
        ("⌘C (Cyrillic)", 8, cmd, "с"), ("⌘V (Cyrillic)", 9, cmd, "м"), ("⌘X (Cyrillic)", 7, cmd, "ч"),
        // Keys that move the caret or edit text, bare (arrows carry fn implicitly).
        ("←", 123, 0, nil), ("→", 124, 0, nil), ("↓", 125, 0, nil), ("↑", 126, 0, nil),
        ("← with fn", 123, fn, nil), ("↑ with fn", 126, fn, nil),
        ("Return", 36, 0, nil), ("Tab", 48, 0, nil), ("Space", 49, 0, nil), ("Delete", 51, 0, nil),
        ("Home", 115, 0, nil), ("End", 119, 0, nil), ("Page Up", 116, 0, nil), ("Page Down", 121, 0, nil),
    ]

    private static func recorder(_ run: inout GauntletRun) {
        func refused(_ code: UInt16, _ mods: UInt64, _ chars: String?) -> Bool {
            if case .refuse = HotkeyRecorderView.keyDownOutcome(keyCode: code, modifiers: mods, characters: chars) { return true }
            return false
        }
        let saved = systemShortcuts.filter { !refused($0.1, $0.2, $0.3) }.map(\.0)
        run.check(saved.isEmpty, id: "F13",
                  "the shortcut recorder refuses every system shortcut on the literal list (\(systemShortcuts.count))",
                  "would save: " + saved.joined(separator: ", "))

        // A menu shortcut follows its LETTER, wherever the layout puts it.
        var strays: [String] = []
        for seed in run.seeds {
            var rng = SeededRandom(seed: seed &+ 0x4004)
            let letter = pick(["c", "v", "x", "z", "a", "q", "w", "h", "m"], &rng)
            let code = UInt16(rng.next() % 110)
            if code == 53 { continue }   // Esc cancels instead
            if !refused(code, cmd, letter) { strays.append("⌘\(letter.uppercased()) on key \(code)") }
        }
        run.check(strays.isEmpty, id: "F13",
                  "…and refuses ⌘ + a menu letter on any key position, as other layouts have it (\(run.seeds.count) seeds)",
                  Set(strays).sorted().prefix(5).joined(separator: ", "))

        // The recorder can still record: a refusal list that refused everything would pass the above.
        let fine: [(String, UInt16, UInt64, String?)] = [("⌥/", 44, opt, "/"), ("⌃⌥.", 47, ctrl | opt, "."), ("F5", 96, 0, nil)]
        let over = fine.filter { entry in
            if case .commit = HotkeyRecorderView.keyDownOutcome(keyCode: entry.1, modifiers: entry.2, characters: entry.3) { return false }
            return true
        }.map(\.0)
        run.check(over.isEmpty, id: "props.recorder-commits",
                  "…but still records ordinary shortcuts (⌥/, ⌃⌥., F5)", "refused: " + over.joined(separator: ", "))
    }
}
