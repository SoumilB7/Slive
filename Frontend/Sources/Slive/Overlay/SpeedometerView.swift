import SwiftUI

/// A semicircular speedometer for speaking pace (words per minute): a cool→warm
/// dial with tick marks and a needle at the current value. Purely a readout —
/// it redraws when `value` changes (once per dictation), so no animation loop.
struct SpeedometerView: View {
    /// Current pace in WPM. 0 → needle/value arc hidden (nothing measured yet).
    var value: Double
    var accent: Color

    /// Dial range. 60–200 spans slow to rapid conversational speech.
    private let lo = 60.0
    private let hi = 200.0
    /// The arc sweeps the top half: 180° (left) → 270° (up) → 360° (right).
    private let startDeg = 180.0
    private let endDeg = 360.0

    private struct Tick { let value: Double; let label: String? }
    private let ticks: [Tick] = [
        .init(value: 60, label: "60"),
        .init(value: 95, label: nil),
        .init(value: 130, label: "130"),
        .init(value: 165, label: nil),
        .init(value: 200, label: "200"),
    ]

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 8)
            let r = min(size.width / 2, size.height) - 16
            guard r > 0 else { return }

            // 1. Track.
            ctx.stroke(
                arc(center: center, radius: r, from: startDeg, to: endDeg),
                with: .color(.white.opacity(0.10)),
                style: StrokeStyle(lineWidth: 12, lineCap: .round))

            let clamped = min(max(value, lo), hi)
            let frac = (clamped - lo) / (hi - lo)
            let needleDeg = startDeg + frac * (endDeg - startDeg)

            // 2. Filled portion up to the needle, cool → warm.
            if value > 0 {
                ctx.stroke(
                    arc(center: center, radius: r, from: startDeg, to: needleDeg),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hue: 0.55, saturation: 0.5, brightness: 0.72),
                            accent,
                            Color(hue: 0.12, saturation: 0.8, brightness: 0.92),
                        ]),
                        startPoint: CGPoint(x: center.x - r, y: center.y),
                        endPoint: CGPoint(x: center.x + r, y: center.y)),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round))
            }

            // 3. Ticks + labels.
            for tick in ticks {
                let f = (tick.value - lo) / (hi - lo)
                let a = startDeg + f * (endDeg - startDeg)
                var tp = Path()
                tp.move(to: point(a, r - 13, center))
                tp.addLine(to: point(a, r - 5, center))
                ctx.stroke(tp, with: .color(.white.opacity(0.28)), lineWidth: 1.5)
                if let label = tick.label {
                    ctx.draw(
                        Text(label)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.4)),
                        at: point(a, r - 26, center))
                }
            }

            // 4. Needle + hub.
            if value > 0 {
                var np = Path()
                np.move(to: point(needleDeg + 180, 8, center))   // small tail past the hub
                np.addLine(to: point(needleDeg, r - 8, center))
                ctx.stroke(np, with: .color(.white),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                     with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)),
                     with: .color(accent))
        }
    }

    /// Point on a circle at `deg` (0°=right, 90°=down, 180°=left, 270°=up in the
    /// Canvas's y-down space) and `radius` from `center`.
    private func point(_ deg: Double, _ radius: Double, _ center: CGPoint) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }

    /// A stroked arc built from short segments so gradient/tick placement stays
    /// exact (no reliance on `clockwise` sign in flipped coordinates).
    private func arc(center: CGPoint, radius: Double, from: Double, to: Double) -> Path {
        var p = Path()
        let steps = 64
        for i in 0...steps {
            let deg = from + (to - from) * Double(i) / Double(steps)
            let pt = point(deg, radius, center)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
