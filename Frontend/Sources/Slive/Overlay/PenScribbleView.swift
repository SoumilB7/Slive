import SwiftUI

/// The continuous-dictation pill animation: a pen nib scribbling a wavy ink line
/// that scrolls past, so live "writing" reads distinctly from the plain waveform
/// pill. Drawn entirely in a `Canvas` (no image assets). The nib sits at a fixed
/// x with fresh ink appearing under it; the written ink scrolls leftward and
/// fades, and the nib bobs up and down with the line — like scribbling.
struct PenScribbleView: View {
    var active: Bool

    private let ink = Color(hue: 0.52, saturation: 0.45, brightness: 0.97)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height * 0.52
                let amp = size.height * 0.30
                let penX = size.width * 0.66          // nib sits here; ink to its left
                let scroll = t * 3.4                  // ink scroll / scribble speed

                // Wavy ink height at absolute x (two sines → a livelier scribble).
                func y(_ x: Double) -> Double {
                    midY + amp * (0.70 * sin(x * 0.9 + scroll)
                                + 0.30 * sin(x * 2.1 + scroll * 1.7))
                }

                // The written ink: a path from the left edge up to the nib.
                var path = Path()
                var x = 0.0
                path.move(to: CGPoint(x: x, y: y(x)))
                while x <= penX {
                    x += 2.0
                    path.addLine(to: CGPoint(x: min(x, penX), y: y(min(x, penX))))
                }
                // Fade the older ink toward the left so it reads as "scrolling away".
                let fade = Gradient(colors: [ink.opacity(0), ink.opacity(0.95)])
                ctx.stroke(
                    path,
                    with: .linearGradient(fade,
                                          startPoint: CGPoint(x: 0, y: 0),
                                          endPoint: CGPoint(x: penX, y: 0)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                )

                // The pen: nib tip on the line, body angled up to the right, with a
                // small grip circle hinting at the hand holding it.
                let tip = CGPoint(x: penX, y: y(penX))
                let body = CGPoint(x: penX + size.height * 0.55, y: y(penX) - size.height * 1.05)
                var pen = Path()
                pen.move(to: tip)
                pen.addLine(to: body)
                ctx.stroke(pen, with: .color(.white.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                // Nib point.
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 1.4, y: tip.y - 1.4, width: 2.8, height: 2.8)),
                         with: .color(.white))
                // Grip (hand hint) near the top of the pen.
                let grip = CGPoint(x: (tip.x + body.x) / 2 + 0.5, y: (tip.y + body.y) / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: grip.x - 2.3, y: grip.y - 2.3, width: 4.6, height: 4.6)),
                         with: .color(.white.opacity(0.85)))
            }
        }
    }
}
