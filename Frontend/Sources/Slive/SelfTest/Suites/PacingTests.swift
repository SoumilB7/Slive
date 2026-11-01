import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Typing pacing
@MainActor
enum PacingTests {
    static let suite = TestSuite(name: "Typing pacing") { t in
        print("[Typing pacing]")
        var ceilingOK = true, floorOK = true
        for cps in [12.0, 30.0, 60.0, 119.0] {
            for remaining in [1, 2, 5, 50, 500] {
                let d = LiveTypist.forwardDelay(remaining: remaining, cps: cps)
                if d > 0.10 { ceilingOK = false }
                if d < 1.0 / cps - 1e-9 { floorOK = false }
            }
        }
        t.check(ceilingOK, "delay never exceeds 100ms ceiling")
        t.check(floorOK, "delay never types faster than configured cps")
        t.check(LiveTypist.forwardDelay(remaining: 2, cps: 30)
                >= LiveTypist.forwardDelay(remaining: 100, cps: 30),
              "bigger backlog never slows typing")
    }
}
