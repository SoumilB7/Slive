import SwiftUI

/// The continuous-dictation pill animation: a clean pen writing an uneven line
/// that scrolls to the left. The line's fixed-but-irregular shape (three
/// out-of-sync sines) just translates, so it reads as continuous handwriting;
/// the pen's nib is pinned to the line's leading end and wobbles gently as it
/// "writes". Drawn entirely in a `Canvas` — no assets. Tuned values are baked in
/// (matched to the approved preview): scroll 34 px/s, wave 5.2, pen 15, etc.
struct PenScribbleView: View {
    var active: Bool

    private let ink = Color(red: 127 / 255, green: 230 / 255, blue: 238 / 255)
    private let border = Color(red: 8 / 255, green: 24 / 255, blue: 26 / 255)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let scroll = t * 34.0                 // leftward scroll speed (px/s)
                let midY = size.height * 0.60          // line sits a touch low → headroom for the pen
                let penX = size.width * 0.56

                // Uneven, non-repeating handwriting height at absolute position wx.
                func waveY(_ wx: Double) -> Double {
                    (0.62 * sin(wx * 0.100)
                   + 0.26 * sin(wx * 0.231 + 1.3)
                   + 0.16 * sin(wx * 0.417 + 2.2)) * 5.2
                }

                // The written line: starts at the pen (right) and trails left,
                // fading out at the far edge.
                var line = Path()
                var x = 2.0
                line.move(to: CGPoint(x: x, y: midY + waveY(x + scroll)))
                while x < penX {
                    x = min(x + 1.0, penX)
                    line.addLine(to: CGPoint(x: x, y: midY + waveY(x + scroll)))
                }
                let fade = Gradient(stops: [
                    .init(color: ink.opacity(0),    location: 0.00),
                    .init(color: ink.opacity(0.95), location: 0.22),
                    .init(color: ink.opacity(1.00), location: 1.00),
                ])
                ctx.stroke(
                    line,
                    with: .linearGradient(fade,
                                          startPoint: CGPoint(x: 0, y: 0),
                                          endPoint: CGPoint(x: penX, y: 0)),
                    style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)
                )

                // The pen, nib pinned to the line's leading end, tilted for writing
                // and wobbling a little about that tip.
                let nibY = midY + waveY(penX + scroll)
                var pen = ctx
                pen.translateBy(x: penX, y: nibY)
                pen.rotate(by: .radians(0.05 * sin(t * 8.0)))
                pen.rotate(by: .degrees(-42))
                drawPen(into: &pen, S: 15)
            }
        }
    }

    /// A clean pen: tapered nib → dark collar → barrel with a clip. Fully ink
    /// blue with a thin dark outline; nib tip at the local origin (on the line).
    private func drawPen(into ctx: inout GraphicsContext, S: Double) {
        let bw = max(0.5, 0.038 * S)          // thin outline
        let hw = 0.11 * S                     // barrel half-width
        let nibLen = 0.36 * S
        let barrelEnd = 1.28 * S

        func paint(_ path: Path) {
            ctx.fill(path, with: .color(ink))
            ctx.stroke(path, with: .color(border), lineWidth: bw)
        }

        // nib: taper from the tip (origin) out to the barrel width
        var nib = Path()
        nib.move(to: .zero)
        nib.addLine(to: CGPoint(x: nibLen, y: -hw * 0.9))
        nib.addLine(to: CGPoint(x: nibLen, y:  hw * 0.9))
        nib.closeSubpath()
        paint(nib)

        // nib slit
        var slit = Path()
        slit.move(to: CGPoint(x: 0.02 * S, y: 0))
        slit.addLine(to: CGPoint(x: nibLen * 0.6, y: 0))
        ctx.stroke(slit, with: .color(border), lineWidth: bw * 0.8)

        // barrel
        let barrel = Path(roundedRect: CGRect(x: nibLen, y: -hw, width: barrelEnd - nibLen, height: hw * 2),
                          cornerRadius: hw * 0.85)
        paint(barrel)

        // dark collar between nib and barrel
        let collar = Path(roundedRect: CGRect(x: nibLen - 0.01 * S, y: -hw, width: 0.11 * S, height: hw * 2),
                          cornerRadius: hw * 0.4)
        ctx.fill(collar, with: .color(border))

        // clip near the top of the barrel
        let clip = Path(roundedRect: CGRect(x: barrelEnd - 0.52 * S, y: -hw - 0.07 * S, width: 0.46 * S, height: 0.11 * S),
                        cornerRadius: 0.05 * S)
        paint(clip)
    }
}
