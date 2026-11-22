import Foundation

// The runner's pure parts: command line, seed plan, known-red ledger and the
// regression store. No processes, no printing: the G9 self-check drives them
// directly.

/// Parsed `Slive --gauntlet …` command line. A typo'd flag is an error, not
/// a silently different run.
struct GauntletOptions {
    /// Which families exist: the real ones, or one of the runner's own
    /// private ones (self-checks that exercise the runner itself).
    enum Suite { case all, demo, canary, stall }

    var suite = Suite.all
    var only: String?
    /// Base seeds are 1…seedCount.
    var seedCount = GauntletSeeds.baseCount
    /// `--seed` / `--seed-range`: exactly these seeds, nothing added.
    var explicitSeeds: [UInt64]?
    var burst: Int?
    var jobs: Int?
    var maxSeconds = 120.0
    var fixtures: String?
    var daily = true
    /// `--demo-crash S`: the demo family kills its process at seed S, to prove
    /// a burst notices a child that dies without answering.
    var demoCrashSeed: UInt64?
    /// A burst's child: no ledger verdict, results on `§G` protocol lines.
    var isBurstChild = false
    var errors: [String] = []

    static let usage = """
        usage: Slive --gauntlet [--only <family>] [--seeds N] [--seed S] [--burst N] \
        [--max-seconds N]
          --seeds N        base seeds 1…N (default 200), plus 50 seeds derived from today's UTC date
          --no-daily       skip the date-derived seeds
          --seed S         replay exactly one seed
          --burst N        N seeds fanned across one child process per core
          --jobs J         children per family for --burst (default: CPU cores)
          --max-seconds N  wall-clock limit for the whole run (default 120)
          --fixtures DIR   Fixtures/gauntlet folder (default: found next to the build)
        """

    init(_ arguments: [String]) {
        var i = 0
        func value(_ flag: String) -> String? {
            guard i + 1 < arguments.count else { errors.append("\(flag) needs a value"); return nil }
            i += 1
            return arguments[i]
        }
        func number<T: LosslessStringConvertible & Comparable>(_ flag: String, min: T) -> T? {
            guard let text = value(flag) else { return nil }
            guard let n = T(text), n >= min else {
                errors.append("\(flag) wants a number ≥ \(min), got '\(text)'")
                return nil
            }
            return n
        }
        var explicit: [UInt64] = []
        var sawExplicit = false
        while i < arguments.count {
            let flag = arguments[i]
            switch flag {
            case "--gauntlet": break
            case "--only": only = value(flag)
            case "--seeds": seedCount = number(flag, min: 0) ?? seedCount
            case "--seed":
                sawExplicit = true
                if let s: UInt64 = number(flag, min: 0) { explicit.append(s) }
            case "--seed-range":
                sawExplicit = true
                if let text = value(flag) {
                    if let ranges = GauntletSeeds.parseRanges(text) { explicit += ranges.flatMap { Array($0) } }
                    else { errors.append("--seed-range wants a:b[,c:d…], got '\(text)'") }
                }
            case "--burst":
                if let n: Int = number(flag, min: 1) { burst = n; seedCount = n }
            case "--jobs": jobs = number(flag, min: 1) ?? jobs
            case "--max-seconds": maxSeconds = number(flag, min: 0.01) ?? maxSeconds
            case "--fixtures": fixtures = value(flag)
            case "--no-daily": daily = false
            case "--demo": suite = .demo
            case "--canary": suite = .canary
            case "--demo-stall": suite = .stall
            case "--demo-crash": demoCrashSeed = number(flag, min: 0)
            case "--burst-child": isBurstChild = true
            default: errors.append("unknown flag \(flag)")
            }
            i += 1
        }
        if sawExplicit { explicitSeeds = explicit }
    }
}

/// Which seeds a run explores: a fixed base set, a daily slice that moves
/// with the UTC date (so coverage grows even when nobody changes anything),
/// and every seed that ever failed.
enum GauntletSeeds {
    static let baseCount = 200
    static let dailyCount = 50
    /// Date-derived seeds sit far above any base set a burst would ask for.
    static let dailyOrigin: UInt64 = 1_000_000

    /// The 50 seeds of the UTC day containing `epochSeconds`. Each day owns a
    /// disjoint block, so yesterday's failure is replayable by number.
    static func daily(epochSeconds: TimeInterval) -> [UInt64] {
        let day = UInt64(max(0, epochSeconds / 86_400))
        let first = dailyOrigin + day * UInt64(dailyCount)
        return Array(first..<(first + UInt64(dailyCount)))
    }

    /// Seeds for one seeded family: `--seed`/`--seed-range` exactly, else
    /// base + daily + the family's saved regression seeds, ascending.
    static func plan(_ options: GauntletOptions, saved: [UInt64], epochSeconds: TimeInterval) -> [UInt64] {
        if let explicit = options.explicitSeeds { return unique(explicit) }
        var seeds = options.seedCount > 0 ? Array(1...UInt64(options.seedCount)) : []
        if options.daily { seeds += daily(epochSeconds: epochSeconds) }
        return unique(seeds + saved)
    }

    private static func unique(_ seeds: [UInt64]) -> [UInt64] { Array(Set(seeds)).sorted() }

    /// Ascending runs of consecutive seeds, as `a:b` ranges.
    static func ranges(_ seeds: [UInt64]) -> [ClosedRange<UInt64>] {
        var out: [ClosedRange<UInt64>] = []
        for s in seeds.sorted() {
            if let last = out.last, s <= last.upperBound &+ 1 {
                if s > last.upperBound { out[out.count - 1] = last.lowerBound...s }
            } else {
                out.append(s...s)
            }
        }
        return out
    }

    static func format(_ ranges: [ClosedRange<UInt64>]) -> String {
        ranges.map { "\($0.lowerBound):\($0.upperBound)" }.joined(separator: ",")
    }

    /// `a:b`, `a` or a comma list of them; nil when malformed or reversed.
    static func parseRanges(_ text: String) -> [ClosedRange<UInt64>]? {
        var out: [ClosedRange<UInt64>] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: ":", omittingEmptySubsequences: false)
            guard bounds.count <= 2, let a = bounds.first.flatMap({ UInt64($0) }) else { return nil }
            let b = bounds.count == 2 ? UInt64(bounds[1]) : a
            guard let b, a <= b else { return nil }
            out.append(a...b)
        }
        return out.isEmpty ? nil : out
    }

    /// `seeds` cut into at most `parts` contiguous slices of near-equal size.
    static func split(_ seeds: [UInt64], into parts: Int) -> [[UInt64]] {
        guard !seeds.isEmpty else { return [] }
        let n = min(max(1, parts), seeds.count)
        let size = (seeds.count + n - 1) / n
        return stride(from: 0, to: seeds.count, by: size).map { Array(seeds[$0..<min($0 + size, seeds.count)]) }
    }
}

/// `Fixtures/gauntlet/known-red.txt`: the checks expected to fail today, each
/// with the reason. A new failure fails the build, and so does a listed id
/// that now passes (the list only shrinks).
struct GauntletLedger {
    private(set) var ids: Set<String> = []
    /// Malformed lines; any of these fails the run, so the ledger can't rot.
    private(set) var problems: [String] = []

    init() {}

    init(parsing text: String, file: String = "known-red.txt") {
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let place = "\(file):\(index + 1)"
            guard let hash = line.firstIndex(of: "#") else {
                problems.append("\(place): '\(line)' has no comment (write `ID  # why it is red`)")
                continue
            }
            let id = line[..<hash].trimmingCharacters(in: .whitespaces)
            let why = line[line.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            if id.isEmpty || id.contains(where: \.isWhitespace) {
                problems.append("\(place): expected one id before the #, got '\(id)'")
            } else if why.isEmpty {
                problems.append("\(place): \(id) has an empty comment")
            } else if !ids.insert(id).inserted {
                problems.append("\(place): \(id) is listed twice")
            }
        }
    }

    struct Verdict: Equatable {
        /// Failed and listed: expected today.
        var knownRed: [String] = []
        /// Failed and not listed: the build fails.
        var new: [String] = []
        /// Listed, ran, and every check passed: remove it from the list.
        var fixed: [String] = []
        /// Listed but never ran this time (filtered out, or the id is stale).
        var notRun: [String] = []
        var passes: Bool { new.isEmpty && fixed.isEmpty }
    }

    func judge(failed: Set<String>, ran: Set<String>) -> Verdict {
        var v = Verdict()
        v.knownRed = failed.intersection(ids).sorted()
        v.new = failed.subtracting(ids).sorted()
        v.fixed = ids.subtracting(failed).intersection(ran).sorted()
        v.notRun = ids.subtracting(failed).subtracting(ran).sorted()
        return v
    }
}

/// Failing seeds saved as `<family>-<seed>.txt` (the shrunk script) so every
/// later run replays them, whatever the base seeds are.
struct GauntletRegressionStore {
    let directory: URL

    static func fileName(family: String, seed: UInt64) -> String { "\(family)-\(seed).txt" }

    /// Family names contain hyphens ("sim-hold"), so the seed is whatever
    /// follows the last one.
    static func parse(fileName: String) -> (family: String, seed: UInt64)? {
        guard fileName.hasSuffix(".txt") else { return nil }
        let stem = fileName.dropLast(4)
        guard let dash = stem.lastIndex(of: "-"), dash != stem.startIndex,
              let seed = UInt64(stem[stem.index(after: dash)...]) else { return nil }
        return (String(stem[..<dash]), seed)
    }

    func savedSeeds(for family: String) -> [UInt64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap(Self.parse(fileName:)).filter { $0.family == family }.map(\.seed).sorted()
    }

    /// Writes the script; returns the file. Unchanged content is left alone
    /// so a replayed failure doesn't touch the working tree.
    @discardableResult
    func save(family: String, seed: UInt64, script: String) -> URL? {
        let url = directory.appendingPathComponent(Self.fileName(family: family, seed: seed))
        let text = script.hasSuffix("\n") ? script : script + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        } catch {
            print("  ✗ couldn't save regression \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
