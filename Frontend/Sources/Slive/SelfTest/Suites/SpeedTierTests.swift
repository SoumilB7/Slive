import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// Speed tiers (the latency ⇄ resources contract)
@MainActor
enum SpeedTierTests {
    static let suite = TestSuite(name: "Speed tiers") { t in
        print("[Speed tiers]")
        t.check(SpeedTier.instant.pinsModels && SpeedTier.instant.primesOnHold
                && SpeedTier.instant.holdsLatencyAssertion && SpeedTier.instant.warmsAfterLoad,
              "Instant spends everything for speed")
        t.check(!SpeedTier.feather.pinsModels && SpeedTier.feather.releasesUnderPressure
                && !SpeedTier.feather.warmsAfterLoad && !SpeedTier.feather.primesOnHold,
              "Feather spends nothing while idle")
        t.check(SpeedTier.snappy.pinsModels && !SpeedTier.snappy.primesOnHold
                && SpeedTier.snappy.holdsLatencyAssertion,
              "Snappy keeps models and clocks, drops per-hold priming")

        let factor = SpeedTier.decodeFactor(for: "large-v3-v20240930_626MB")
        let latencies = SpeedTier.allCases.map { $0.estimatedLatency(modelFactor: factor) }
        t.check(latencies == latencies.sorted() && Set(latencies).count == latencies.count,
              "tier latencies strictly increase Instant → Feather")
        let energies = SpeedTier.allCases.map(\.energyIndex)
        t.check(energies == energies.sorted(by: >) && Set(energies).count == energies.count,
              "tier energy strictly decreases Instant → Feather")
        // Battery drain: real numbers, checked as numbers.
        let drains = SpeedTier.allCases.map(\.drainMWhPerHour)
        t.check(drains == drains.sorted(by: >) && Set(drains).count == drains.count,
              "tier battery drain (mWh/hr) strictly decreases Instant → Feather")
        t.check(SpeedTier.feather.drainMWhPerHour == 0,
              "Feather drains nothing above baseline")
        // Instant = 80 mW idle + 3.5 J × 30/hr ÷ 3.6 = 109.2 mWh/hr.
        t.check(abs(SpeedTier.instant.drainMWhPerHour - 109.2) < 0.3,
              "Instant drain math: 80 mW + 3.5 J × 30/3.6 ≈ 109 mWh/hr")
        // On a 53 Wh Air battery that is ≈0.206 %/hr.
        if let pct = SpeedTier.instant.drainPercentPerHour(batteryWh: 53) {
            t.check(abs(pct - 0.206) < 0.01, "percent math: 109 mWh over 53 Wh ≈ 0.21%/hr")
        } else {
            t.check(false, "percent math returned nil for a real battery")
        }
        t.check(SpeedTier.instant.drainPercentPerHour(batteryWh: nil) == nil,
              "no battery (desktop) → no percent claim")
        t.check(SpeedTier.instant.batteryIndex == 1,
              "chart battery fraction tops out at Instant")
        // Receipts quote units, not adjectives.
        let withBattery = SpeedTier.instant.costLines(modelResidentGB: 1.2, batteryWh: 53)
        t.check(withBattery.first { $0.0 == "Battery" }?.1.contains("%/hr") == true,
              "battery receipt quotes %/hr on machines with a battery")
        let noBattery = SpeedTier.snappy.costLines(modelResidentGB: 1.2, batteryWh: nil)
        t.check(noBattery.first { $0.0 == "Battery" }?.1.contains("mWh") == true,
              "battery receipt falls back to mWh on wall-powered Macs")
        t.check(SpeedTier.allCases.allSatisfy { tier in
            tier.costLines(modelResidentGB: 1.2, batteryWh: 53).contains { $0.0 == "Battery" }
        }, "every tier's receipt itemizes battery")
        // The machine checker's battery read, when present, must be sane
        // laptop territory (guards the mAh-vs-percent IOKit trap).
        t.check(MachineProfile.batteryWh.map { $0 > 20 && $0 < 120 } ?? true,
              "measured battery capacity is in sane laptop range",
              "got \(String(describing: MachineProfile.batteryWh))")
        t.check(SpeedTier.feather.estimatedRamGB(modelResidentGB: 1.2) < 0.1,
              "Feather's idle RAM is near zero")

        let xs = LatencyGraphView.xPositions(latencies: latencies, width: 400)
        t.check(xs == xs.sorted() && xs.first! >= 0 && xs.last! <= 400,
              "graph x-positions are ordered and inside the plot")
        t.check(LatencyGraphView.ms(0.34) == "~340ms" && LatencyGraphView.ms(1.2) == "~1.2s",
              "latency labels format ms under 1s, seconds above")

        // Calibration: measured typical-decode seconds override the guess.
        let measured = SpeedTier.effectiveFactor(measuredTypicalDecode: 0.62, model: "large-v3")
        t.check(measured.measured && measured.factor == 0.62,
              "measured decode seconds drive the graph directly (no scaling)")
        let fallback = SpeedTier.effectiveFactor(measuredTypicalDecode: nil, model: "large-v3")
        t.check(!fallback.measured && fallback.factor == SpeedTier.decodeFactor(for: "large-v3"),
              "no calibration falls back to the family estimate")
        let poisoned = SpeedTier.effectiveFactor(measuredTypicalDecode: 45, model: "large-v3")
        t.check(poisoned.factor <= 10,
              "a poisoned calibration value can never put absurd numbers on the axis")
        t.check(TranscriptionModel.blendedRate(old: nil, new: 0.2) == 0.2
                && abs(TranscriptionModel.blendedRate(old: 0.2, new: 0.4) - 0.26) < 0.0001,
              "decode-rate EMA seeds on first sample, blends 70/30 after")
        t.check(!TranscriptionModel.acceptableCalibrationClip(1.0)
                && TranscriptionModel.acceptableCalibrationClip(8)
                && !TranscriptionModel.acceptableCalibrationClip(45),
              "calibration only trusts one-window, dictation-sized clips (3–30s)")

        // The machine checker behind the graph caption.
        t.check(MachineProfile.ramGB > 0, "machine checker reads physical RAM")
        t.check(MachineProfile.summary.contains("GB") && !MachineProfile.chip.isEmpty,
              "machine summary names the chip and RAM")
    }
}
