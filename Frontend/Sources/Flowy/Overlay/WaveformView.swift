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
                let level = CGFloat(min(1, max(0, levels[i])))
                let h = max(minBar, level * maxBar)
                let x = CGFloat(i) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                ctx.fill(path, with: .color(color(level: level)))
            }
        }
    }

    /// Off-matte blue: low saturation (flat, not neon), gently brighter louder.
    private func color(level: CGFloat) -> Color {
        Color(hue: 0.58,
              saturation: 0.42,
              brightness: 0.60 + 0.30 * Double(level),
              opacity: 0.55 + 0.40 * Double(level))
    }
}
