import Foundation
import SliveTestKit

// The Gauntlet's shared contract (design: z-docs/engineering/gauntlet.md).
// Families are built in parallel against these types; the runner
// (`Slive --gauntlet`, GauntletRunner.swift) owns seeds, the known-red ledger,
// regression replay and bursts.

/// One family of Gauntlet checks: a world simulator, a failure matrix, an
/// upgrade replay… Seeded families explore `run.seeds`; others ignore them.
@MainActor struct GauntletFamily {
    /// Short id used by `--only` and in check ids: "sim-hold", "upgrade", …
    let name: String
    let seeded: Bool
    let run: @MainActor (inout GauntletRun) -> Void
}

/// What a family records into. Every check carries an id — a finding
/// ("F6"), a promise ("P-NO-LOSS") or the family's own ("sim-hold.liveness")
/// — so the known-red ledger can match failures to findings.
@MainActor struct GauntletRun {
    var checks = Checks()
    /// Seeds to explore this run (empty for unseeded families).
    let seeds: [UInt64]
    /// Failing seeds, each with the shrunk, human-readable event script
    /// that reproduces it (saved under Fixtures/gauntlet/regressions/).
    private(set) var regressions: [(family: String, seed: UInt64, script: String)] = []
    /// Ids of checks that failed this run (the ledger compares these).
    private(set) var failedIDs: [String] = []
    /// Ids of every check that ran, pass or fail: the ledger's ratchet only
    /// calls a known-red id fixed when its checks actually ran and passed.
    private(set) var ranIDs: Set<String> = []

    init(seeds: [UInt64]) { self.seeds = seeds }

    mutating func check(_ ok: Bool, id: String, _ name: String, _ detail: String = "") {
        ranIDs.insert(id)
        checks.check(ok, "[\(id)] \(name)", detail)
        if !ok { failedIDs.append(id) }
    }

    mutating func regression(family: String, seed: UInt64, script: String) {
        regressions.append((family, seed, script))
    }
}

/// Deterministic, splittable RNG (SplitMix64): the same seed replays the
/// same world on every machine.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Every family, in run order. Adding one = one file in Gauntlet/ plus one
/// line here.
@MainActor enum GauntletFamilies {
    static let all: [GauntletFamily] = [
        GauntletHarness.family,
        SimHold.family,
        SimLive.family,
        SimKeys.family,
        SimRecorder.family,
        UpgradeFamily.family,
        EgressFamily.family,
        PropsFamily.family,
    ]
}
