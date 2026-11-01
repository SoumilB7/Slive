import Foundation
import SliveTestKit

/// What the speed-tier graph reads from this Mac and the decoder (the tiers
/// themselves: SpeedTierTests in SliveCoreSuites).
@MainActor
enum SpeedTierMachineTests {
    static let suite = TestSuite(name: "Speed tiers — machine + graph") { t in
        print("[Speed tiers — machine + graph]")
        let factor = SpeedTier.decodeFactor(for: "large-v3-v20240930_626MB")
        let latencies = SpeedTier.allCases.map { $0.estimatedLatency(modelFactor: factor) }

        // The machine checker's battery read, when present, must be sane
        // laptop territory (guards the mAh-vs-percent IOKit trap).
        t.check(MachineProfile.batteryWh.map { $0 > 20 && $0 < 120 } ?? true,
              "measured battery capacity is in sane laptop range",
              "got \(String(describing: MachineProfile.batteryWh))")

        let xs = LatencyGraphView.xPositions(latencies: latencies, width: 400)
        t.check(xs == xs.sorted() && xs.first! >= 0 && xs.last! <= 400,
              "graph x-positions are ordered and inside the plot")
        t.check(LatencyGraphView.ms(0.34) == "~340ms" && LatencyGraphView.ms(1.2) == "~1.2s",
              "latency labels format ms under 1s, seconds above")

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
