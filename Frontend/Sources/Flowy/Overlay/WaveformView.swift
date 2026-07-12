import SwiftUI

/// Thin, matte off-blue "moving lines" — vertical bars mirrored around the
/// centre line. Flat (no glow) to keep it quiet on a black pill; each line
/// gets slightly brighter as it rises.
struct WaveformView: View {
    var levels: [Float]

    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            guard n > 0 else { return }

            let spacing: CGFloat = 1.5
            let barWidth = max(1.5, (size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            let midY = size.height / 2
            let maxBar = size.height
            let minBar = barWidth               // fully-rounded dot at rest

            for i in 0..<n {
                // Mirror-symmetric, tallest in the middle (mic-icon shape).
                let base = CGFloat(min(1, max(0, levels[bandIndex(for: i, count: n)])))
                let level = base * envelope(for: i, count: n)
                let h = max(minBar, level * maxBar)
                let x = CGFloat(i) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                ctx.fill(path, with: .color(color(level: level)))
            }
        }
    }

    /// Map a display position to a frequency band by distance from centre, so
    /// the loudest low frequencies land in the middle and equidistant bars share
    /// a band — a symmetric shape instead of a left-to-right ramp.
    private func bandIndex(for i: Int, count n: Int) -> Int {
        guard n > 1 else { return 0 }
        let mid = Double(n - 1) / 2.0
        let dist = abs(Double(i) - mid) / mid          // 0 centre … 1 edges
        return Int((dist * Double(n - 1)).rounded())
    }

    /// Arch envelope: full height at the centre, tapering toward the edges.
    private func envelope(for i: Int, count n: Int) -> CGFloat {
        guard n > 1 else { return 1 }
        let p = Double(i) / Double(n - 1)              // 0 … 1
        return CGFloat(0.4 + 0.6 * sin(.pi * p))
    }

    /// Off-matte blue: low saturation (flat, not neon), gently brighter louder.
    private func color(level: CGFloat) -> Color {
        Color(hue: 0.58,
              saturation: 0.42,
              brightness: 0.60 + 0.30 * Double(level),
              opacity: 0.55 + 0.40 * Double(level))
    }
}
