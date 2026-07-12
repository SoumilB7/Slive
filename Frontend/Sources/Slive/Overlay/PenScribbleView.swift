import SwiftUI

/// The continuous-dictation pill animation: one continuous handwriting squiggle
/// that scrolls steadily to the left (its shape is fixed — it just translates),
/// with a small clean pen riding on it that bobs up and down as the line passes
/// under the nib, reading as live writing. Drawn entirely in a `Canvas`, no
/// assets, and no "hand" — just the line and a thin pen.
struct PenScribbleView: View {
    var active: Bool

    private let ink = Color(hue: 0.52, saturation: 0.5, brightness: 0.98)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height * 0.5
                let amp = size.height * 0.26
                // A gentle, fixed-shape wave (~2.5 humps across) that scrolls left.
                let k = 2.0 * Double.pi / (size.width * 0.40)
                let phase = t * 3.4                      // scroll speed (leftward)

                func y(_ x: Double) -> Double { midY + amp * sin(k * x + phase) }

                // The single continuous line across the whole pill.
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(0)))
                var x = 1.5
                while x <= size.width {
                    line.addLine(to: CGPoint(x: x, y: y(x)))
                    x += 1.5
                }
                // Fade both ends so the line doesn't hard-cut at the capsule edges.
                let grad = Gradient(stops: [
                    .init(color: ink.opacity(0),    location: 0.00),
                    .init(color: ink.opacity(0.95), location: 0.14),
                    .init(color: ink.opacity(0.95), location: 0.86),
                    .init(color: ink.opacity(0),    location: 1.00),
                ])
                ctx.stroke(
                    line,
                    with: .linearGradient(grad,
                                          startPoint: .zero,
                                          endPoint: CGPoint(x: size.width, y: 0)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )

                // A thin, clean pen sitting on the line — nib on the wave, body
                // angled up to the right. No grip / hand.
                let penX = size.width * 0.66
                let tip = CGPoint(x: penX, y: y(penX))
                let top = CGPoint(x: penX + size.height * 0.34, y: tip.y - size.height * 0.72)
                var pen = Path()
                pen.move(to: tip)
                pen.addLine(to: top)
                ctx.stroke(pen, with: .color(.white.opacity(0.92)),
                           style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
            }
        }
    }
}
