import SwiftUI

/// The audio-reactive waveform: vertical bars mirrored around the centre line,
/// tinted across a blue→violet→pink spectrum, brightness driven by level, with
/// a soft blurred glow pass underneath for that lit-from-within feel.
struct WaveformView: View {
    var levels: [Float]

    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            guard n > 0 else { return }

            let spacing: CGFloat = 3
            let barWidth = max(2.5, (size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            let midY = size.height / 2
            let maxBar = size.height * 0.94
            let minBar = barWidth               // fully-rounded dot at rest

            func barPath(_ i: Int) -> (Path, CGFloat) {
                let level = CGFloat(min(1, max(0, levels[i])))
                let h = max(minBar, level * maxBar)
                let x = CGFloat(i) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                return (Path(roundedRect: rect, cornerRadius: barWidth / 2), level)
            }

            // Soft glow pass — subtle, drawn behind.
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 3.5))
                for i in 0..<n {
                    let (path, level) = barPath(i)
                    layer.fill(path, with: .color(color(at: i, count: n, level: level, glow: true)))
                }
            }

            // Sharp pass on top.
            for i in 0..<n {
                let (path, level) = barPath(i)
                ctx.fill(path, with: .color(color(at: i, count: n, level: level, glow: false)))
            }
        }
    }

    /// Spectrum tint: blue (left) → violet → pink (right), brightness and
    /// opacity rising with the bar's level.
    private func color(at i: Int, count: Int, level: CGFloat, glow: Bool) -> Color {
        let t = count > 1 ? Double(i) / Double(count - 1) : 0
        let hue = 0.60 + 0.32 * t
        let sat = 0.60
        let bri = 0.80 + 0.20 * Double(level)
        let opacity = glow
            ? 0.10 + 0.18 * Double(level)
            : 0.42 + 0.42 * Double(level)
        return Color(hue: hue, saturation: sat, brightness: bri, opacity: opacity)
    }
}
