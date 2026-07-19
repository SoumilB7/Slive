import Foundation

/// The latency ⇄ resources contract, as discrete, honest configurations.
///
/// Every tier is a real set of engineering knobs — nothing cosmetic. The only
/// knobs that appear here are the ones with a genuine resource price; pure
/// wins (adaptive release tail, silence trimming, single decode fallback,
/// VAD-parallel chunking) are always on for every tier and never traded away.
///
/// Ordered fastest-first: raw value is the persisted setting.
enum SpeedTier: Int, CaseIterable, Identifiable {
    case instant = 0    // everything hot, machine held at speed
    case snappy = 1     // hot models + clocks, no per-hold priming
    case relaxed = 2    // hot models, default clocks
    case feather = 3    // models released after idle

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .instant: return "Instant"
        case .snappy: return "Snappy"
        case .relaxed: return "Relaxed"
        case .feather: return "Feather"
        }
    }

    // MARK: - The actual knobs (read by AppDelegate / TranscriptionModel)

    /// Model pipes stay resident in RAM/ANE forever (vs idle release).
    var pinsModels: Bool { self != .feather }
    /// Release idle models after this long (nil = never).
    var idleUnloadAfter: TimeInterval? { self == .feather ? 600 : nil }
    /// Cold-prime the ANE graph at hold-start when minutes have passed.
    var primesOnHold: Bool { self == .instant }
    /// Hold a `.latencyCritical` activity for hold→type (P-cores clocked).
    var holdsLatencyAssertion: Bool { self == .instant || self == .snappy }
    /// Run a tiny warmup decode right after a model loads.
    var warmsAfterLoad: Bool { self != .feather }

    // MARK: - Honest cost estimates (surface for the graph)

    /// Typical release→typed seconds for a short dictation on Apple silicon,
    /// given the decode-speed factor of the selected model. Estimates, and
    /// labeled as such in the UI — the NSLog timing lines are ground truth.
    func estimatedLatency(modelFactor: Double) -> Double {
        let base = 0.09 + modelFactor + 0.02   // tail + decode + dispatch
        switch self {
        case .instant: return base
        case .snappy: return base + 0.10       // occasional cold graph
        case .relaxed: return base + 0.20      // default clocks, esp. battery
        case .feather: return base + 0.25      // and seconds after an idle gap
        }
    }

    /// Resident RAM attributable to dictation models (GB), given the loaded
    /// footprint of the selected model. Feather idles at ~0.
    func estimatedRamGB(modelResidentGB: Double) -> Double {
        pinsModels ? modelResidentGB : 0.05
    }

    /// Relative energy index 0…1 for the chart's second series (assertion
    /// clocks + per-hold priming are the real spenders).
    var energyIndex: Double {
        switch self {
        case .instant: return 1.0
        case .snappy: return 0.7
        case .relaxed: return 0.35
        case .feather: return 0.15
        }
    }

    /// What this tier spends, in words — shown under the graph so the click
    /// says exactly what it buys and costs.
    func costLines(modelResidentGB: Double) -> [(String, String)] {
        let ram = pinsModels
            ? String(format: "≈%.1f GB always resident", modelResidentGB)
            : "freed after 10 idle minutes"
        let clocks = holdsLatencyAssertion
            ? "held at full speed while dictating"
            : "system-managed (may downclock on battery)"
        let prime = primesOnHold
            ? "ANE pre-warmed on every cold hold"
            : (warmsAfterLoad ? "warmed once per model load" : "no warmups")
        let idle = pinsModels
            ? "instant, always"
            : "reloads on first hold after a break (seconds)"
        return [("Model RAM", ram), ("CPU clocks", clocks),
                ("Neural Engine", prime), ("After idle", idle)]
    }

    // MARK: - Model-derived inputs

    /// Decode-speed factor: rough seconds to decode a short (~8s) dictation
    /// on the Neural Engine, by checkpoint family.
    static func decodeFactor(for model: String) -> Double {
        let m = model.lowercased()
        if m.contains("tiny") { return 0.12 }
        if m.contains("base") { return 0.18 }
        if m.contains("small") { return 0.35 }
        if m.contains("medium") { return 0.55 }
        return 0.45   // large-v3 turbo/optimized ("Balanced") and fine-tunes of it
    }

    /// Loaded RAM footprint (GB) by checkpoint family (weights + runtime).
    static func residentGB(for model: String) -> Double {
        let m = model.lowercased()
        if m.contains("tiny") { return 0.2 }
        if m.contains("base") { return 0.35 }
        if m.contains("small") { return 0.9 }
        if m.contains("medium") { return 2.2 }
        return 1.2   // the 626MB Balanced package resident
    }
}
