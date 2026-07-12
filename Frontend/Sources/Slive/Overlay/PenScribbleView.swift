import SwiftUI

/// The continuous-dictation pill animation: a clean pen writing an uneven line
/// that scrolls to the left. The line's fixed-but-irregular shape (three
/// out-of-sync sines) just translates, so it reads as continuous handwriting;
/// the pen's nib is pinned to the line's leading end and wobbles gently as it
/// "writes". Drawn entirely in a `Canvas` — no assets. Tuned values are baked in
/// (matched to the approved preview): scroll 34 px/s, wave 5.2, pen 15, etc.
///
/// Efficiency: only the written line actually changes per frame. The stroke
/// fade gradient and the entire pen glyph are constants (the glyph lives in
/// local nib-at-origin space; the per-frame wobble is a context transform), so
/// both are built exactly once as statics instead of ~7 allocations per frame.
struct PenScribbleView: View {
    var active: Bool

    private static let ink = Color(red: 127 / 255, green: 230 / 255, blue: 238 / 255)
    private static let border = Color(red: 8 / 255, green: 24 / 255, blue: 26 / 255)

    /// Constant left-edge fade for the written line — was rebuilt every frame.
    private static let fade = Gradient(stops: [
        .init(color: ink.opacity(0),    location: 0.00),
        .init(color: ink.opacity(0.95), location: 0.22),
        .init(color: ink.opacity(1.00), location: 1.00),
    ])

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
                ctx.stroke(
                    line,
                    with: .linearGradient(Self.fade,
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
                Self.drawPen(into: &pen)
            }
        }
    }

    // MARK: - Pen glyph (built once; constant local-space geometry)

    /// The pen's five sub-paths in local nib-at-origin space, built ONCE for the
    /// constant S = 15. If S ever becomes dynamic, key this cache by S.
    private struct PenGlyph {
        let nib: Path
        let slit: Path
        let barrel: Path
        let collar: Path
        let clip: Path
        let bw: Double
    }

    private static let glyph: PenGlyph = {
        let S = 15.0
        let bw = max(0.5, 0.038 * S)          // thin outline
        let hw = 0.11 * S                     // barrel half-width
        let nibLen = 0.36 * S
        let barrelEnd = 1.28 * S

        // nib: taper from the tip (origin) out to the barrel width
        var nib = Path()
        nib.move(to: .zero)
        nib.addLine(to: CGPoint(x: nibLen, y: -hw * 0.9))
        nib.addLine(to: CGPoint(x: nibLen, y:  hw * 0.9))
        nib.closeSubpath()

        // nib slit
        var slit = Path()
        slit.move(to: CGPoint(x: 0.02 * S, y: 0))
        slit.addLine(to: CGPoint(x: nibLen * 0.6, y: 0))

        let barrel = Path(roundedRect: CGRect(x: nibLen, y: -hw, width: barrelEnd - nibLen, height: hw * 2),
                          cornerRadius: hw * 0.85)
        let collar = Path(roundedRect: CGRect(x: nibLen - 0.01 * S, y: -hw, width: 0.11 * S, height: hw * 2),
                          cornerRadius: hw * 0.4)
        let clip = Path(roundedRect: CGRect(x: barrelEnd - 0.52 * S, y: -hw - 0.07 * S, width: 0.46 * S, height: 0.11 * S),
                        cornerRadius: 0.05 * S)
        return PenGlyph(nib: nib, slit: slit, barrel: barrel, collar: collar, clip: clip, bw: bw)
    }()

    /// Paint the cached glyph: fully ink blue with a thin dark outline; nib tip
    /// at the local origin (on the line). The caller applies the transform.
    private static func drawPen(into ctx: inout GraphicsContext) {
        let g = glyph
        func paint(_ path: Path) {
            ctx.fill(path, with: .color(ink))
            ctx.stroke(path, with: .color(border), lineWidth: g.bw)
        }
        paint(g.nib)
        ctx.stroke(g.slit, with: .color(border), lineWidth: g.bw * 0.8)
        paint(g.barrel)
        ctx.fill(g.collar, with: .color(border))
        paint(g.clip)
    }
}
