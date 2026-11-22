import Combine
import Foundation
import SliveTestKit

/// G1 — the world simulator for the hold-to-talk path (design:
/// z-docs/engineering/gauntlet.md). A seeded chaos user scripts presses,
/// releases, toggles, ✕, model changes and auto-insert flips over virtual
/// time; a seeded chaos world resolves every async completion (decode, model
/// load, stand-in, delivery receipt, mic loss, slow decode) at random virtual
/// delays. The REAL `SessionCoordinator`, `HoldCapture`, `DictateMode`,
/// `AssistMode`, `DictationQueue`, `InFlightWork`, `OverlayPresenter`,
/// `awaitServing` and `DeliveryVerifier.step` run on fakes at the
/// `ModeContext` seams.
///
/// Each utterance carries a unique token (`w17`) from fake audio through fake
/// speech; a fake field holds the real typed text. After every step and at
/// the end the oracle checks the promises below; a failing seed is
/// delta-debugged to the shortest script that still fails.
@MainActor
enum SimHold {
    static let family = GauntletFamily(name: "sim-hold", seeded: true, run: run)

    /// Virtual seconds a model wait may not exceed once its model can't
    /// arrive or another serving model exists (P-EVERY-WAIT-BOUNDED). The
    /// production cap is 300 s; the extra gives the decode/dispatch headroom.
    static let waitBoundSeconds: Double = 310
    /// How far the driver lets virtual time run before declaring a wait
    /// unbounded — past the bound, so a stuck wait is visible.
    static let virtualCap: Double = 400

    private static func run(_ r: inout GauntletRun) {
        let settings = Self.settings
        var firstFail: [String: (seed: UInt64, script: String)] = [:]
        var noiseCount = 0, utteranceCount = 0

        for seed in r.seeds {
            let script = generateScript(seed: seed)
            let world = SimHoldWorld(seed: seed, settings: settings)
            let result = world.run(script)
            noiseCount += result.noise
            utteranceCount += result.utterances
            for id in result.failingIDs where firstFail[id] == nil {
                let minimal = shrink(seed: seed, script: script, failingID: id, settings: settings)
                firstFail[id] = (seed, render(minimal, seed: seed))
            }
        }

        for (id, name) in checkNames {
            if let fail = firstFail[id] {
                r.check(false, id: id, name, "seed \(fail.seed)")
                r.regression(family: "sim-hold", seed: fail.seed, script: fail.script)
            } else {
                r.check(true, id: id, name)
            }
        }

        // The noise budget: a dictation that both typed-confirmed AND showed a
        // box. Reported either way (P-NO-LOSS tolerates ≤5%).
        let rate = utteranceCount == 0 ? 0 : Double(noiseCount) / Double(utteranceCount)
        r.check(rate <= 0.05, id: "P-NO-LOSS",
                "typed+box noise within 5% budget",
                String(format: "%.2f%% (%d/%d)", rate * 100, noiseCount, utteranceCount))
    }

    /// The invariant ids this family reports, each checked once over all seeds.
    private static let checkNames: [(String, String)] = [
        ("P-NO-LOSS", "every released dictation ends typed-confirmed, boxed, or noticed+kept"),
        ("sim-hold.order", "the field holds the landed tokens in spoken order"),
        ("sim-hold.one-owner", "no box for a dictation covers a newer live hold"),
        ("P-EVERY-WAIT-BOUNDED", "no dictation waits past the bound once its model can't arrive"),
        ("sim-hold.quiescent", "the run ends with an empty queue, idle work and a resting overlay"),
        ("F14", "a training pair is made only for the picked model that decoded it"),
        ("F8", "a mic lost mid-hold is surfaced, never typed silently"),
    ]

    /// One Settings, reused across seeds and reset per world (its init reads
    /// the login-item state — costly to rebuild 200 times).
    static let settings = Settings(store: InMemoryStore())

    // MARK: - Shrinking

    /// Delta-debug the script to the shortest prefix-free subsequence that
    /// still fails `failingID`, replayed on the same seed (same world).
    private static func shrink(seed: UInt64, script: [SimStep], failingID: String,
                               settings: Settings) -> [SimStep] {
        func fails(_ steps: [SimStep]) -> Bool {
            let world = SimHoldWorld(seed: seed, settings: settings)
            return world.run(steps).failingIDs.contains(failingID)
        }
        guard fails(script) else { return script }
        var current = script
        var changed = true
        while changed {
            changed = false
            for i in current.indices {
                var trial = current
                trial.remove(at: i)
                if fails(trial) { current = trial; changed = true; break }
            }
        }
        return current
    }

    /// The minimal script as replayable lines (`t=0.00 press dictate`).
    private static func render(_ steps: [SimStep], seed: UInt64) -> String {
        var t = 0.0
        var lines = ["# sim-hold seed \(seed)"]
        for step in steps {
            t += step.gap
            lines.append(String(format: "t=%.2f %@", t, step.event.description))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Chaos user

    /// The scripted gestures a seed draws from. Each expands to primitive
    /// key/toggle steps with the gaps that make it what it is — a long hold's
    /// tail, a re-press, a toggle session.
    private enum Template: CaseIterable {
        case hold, quickTap, longHoldTailToggle, rePress, toggleSession,
             changeModelHold, assistHold, dismissDuringHold
    }

    /// Build a script: a handful of templates, some settings flips between.
    private static func generateScript(seed: UInt64) -> [SimStep] {
        var rng = SeededRandom(seed: seed)
        var steps: [SimStep] = []
        let count = Int.random(in: 2...4, using: &rng)
        for _ in 0..<count {
            let template = Template.allCases.randomElement(using: &rng)!
            let action: HotkeyAction = Bool.random(using: &rng) ? .dictate : .assist
            steps += expand(template, action: action, rng: &rng)
            if Bool.random(using: &rng) {
                steps.append(SimStep(gap: Double.random(in: 0...0.2, using: &rng), event: .flipAuto))
            }
        }
        return steps
    }

    private static func expand(_ template: Template, action: HotkeyAction,
                               rng: inout SeededRandom) -> [SimStep] {
        let lead = Double.random(in: 0.1...0.6, using: &rng)
        switch template {
        case .hold:
            return [SimStep(gap: lead, event: .press(action)),
                    SimStep(gap: Double.random(in: 0.3...2.0, using: &rng), event: .release)]
        case .quickTap:
            return [SimStep(gap: lead, event: .press(action)),
                    SimStep(gap: 0.05, event: .release)]   // under the 0.15 s hold delay
        case .longHoldTailToggle:
            // A real, long dictation, then a toggle tap inside its 0.1 s tail
            // (F17: the tap used to abort the long hold as a false start).
            return [SimStep(gap: lead, event: .press(.dictate)),
                    SimStep(gap: 1.5, event: .release),
                    SimStep(gap: 0.03, event: .toggle(.dictate))]
        case .rePress:
            return [SimStep(gap: lead, event: .press(action)),
                    SimStep(gap: 0.5, event: .release),
                    SimStep(gap: Double.random(in: 0...0.3, using: &rng), event: .press(action)),
                    SimStep(gap: Double.random(in: 0.4...1.0, using: &rng), event: .release)]
        case .toggleSession:
            return [SimStep(gap: lead, event: .toggle(action)),
                    SimStep(gap: Double.random(in: 0.5...1.5, using: &rng), event: .toggle(action))]
        case .changeModelHold:
            return [SimStep(gap: lead, event: .setModel("whisper2")),
                    SimStep(gap: 0.1, event: .press(.dictate)),
                    SimStep(gap: 1.0, event: .release)]
        case .assistHold:
            return [SimStep(gap: lead, event: .press(.assist)),
                    SimStep(gap: 0.8, event: .release)]
        case .dismissDuringHold:
            return [SimStep(gap: lead, event: .press(action)),
                    SimStep(gap: 0.6, event: .release),
                    SimStep(gap: 0.05, event: .dismiss)]
        }
    }
}

// MARK: - Script model

/// One scripted step: wait `gap` virtual seconds, then do `event`.
struct SimStep {
    let gap: TimeInterval
    let event: SimEvent
}

enum SimEvent: CustomStringConvertible {
    case press(HotkeyAction)
    case release
    case toggle(HotkeyAction)
    case dismiss
    case setModel(String)
    case flipAuto

    var description: String {
        switch self {
        case .press(let a): return "press \(a)"
        case .release: return "release"
        case .toggle(let a): return "toggle \(a)"
        case .dismiss: return "dismiss"
        case .setModel(let m): return "set model \(m)"
        case .flipAuto: return "flip autoInsert"
        }
    }
}
