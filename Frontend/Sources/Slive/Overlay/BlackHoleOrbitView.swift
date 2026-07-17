import SwiftUI

/// Assistant-mode listening animation: a small "black hole" — a near-black disc
/// ringed by a thin teal accretion glow, with a bright mass orbiting it in a
/// circle. A short fading trail sells the orbital motion; the orbit is slightly
/// elliptical and the mass runs a touch faster on one side, as if pulled by
/// gravity. Shown (in place of the dictation waveform) while the assistant
/// hotkey is held. Fills a ~40×40 frame and only animates while `active`.
///
/// Efficiency structure: the halo, accretion ring, and core disc depend only on
/// the view's size — never on time — so they live in their own Canvas OUTSIDE
/// the TimelineView. SwiftUI renders that layer once and composites it, instead
/// of rebuilding ~5 paths + 2 radial gradients on every animation frame. Only
/// the trail + orbiting mass redraw per frame, capped at 60fps (uncapped, this
/// ran at 120Hz on ProMotion for no visible benefit).
struct BlackHoleOrbitView: View {
    var active: Bool

    /// App teal accent — used for the ring, glow and orbiting mass.
    private let teal = Color(hue: 0.50, saturation: 0.68, brightness: 0.86)

    var body: some View {
        ZStack {
            // Static layers: size-only geometry, drawn once per layout.
            Canvas { ctx, size in
                Self.drawStaticLayers(ctx, size: size, teal: teal)
            }
            // Animated layers: trail + mass, 60fps while active.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    Self.drawOrbit(ctx, size: size, t: t, teal: teal)
                }
            }
        }
    }

    // MARK: - Static geometry (no time dependence)

    private static func drawStaticLayers(_ ctx: GraphicsContext, size: CGSize, teal: Color) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let minSide = min(size.width, size.height)
        let coreR = minSide * 0.30
        let ringR = coreR * 1.06

        // Faint warp halo around the core.
        let haloR = minSide * 0.5
        let halo = Path(ellipseIn: CGRect(x: center.x - haloR,
                                          y: center.y - haloR,
                                          width: haloR * 2,
                                          height: haloR * 2))
        ctx.fill(halo, with: .radialGradient(
            Gradient(colors: [teal.opacity(0.16), .clear]),
            center: center,
            startRadius: coreR * 0.6,
            endRadius: haloR))

        // Accretion ring: a glowing teal edge, brightest around the disc.
        let ringRect = CGRect(x: center.x - ringR,
                              y: center.y - ringR,
                              width: ringR * 2,
                              height: ringR * 2)
        ctx.stroke(Path(ellipseIn: ringRect.insetBy(dx: -1.5, dy: -1.5)),
                   with: .color(teal.opacity(0.22)),
                   lineWidth: minSide * 0.09)      // soft outer glow
        ctx.stroke(Path(ellipseIn: ringRect),
                   with: .color(teal.opacity(0.95)),
                   lineWidth: max(1, minSide * 0.03))  // crisp bright ring

        // Central black-hole disc: dark core with a barely-lit rim.
        let coreRect = CGRect(x: center.x - coreR,
                              y: center.y - coreR,
                              width: coreR * 2,
                              height: coreR * 2)
        ctx.fill(Path(ellipseIn: coreRect), with: .radialGradient(
            Gradient(colors: [.black,
                              Color(white: 0.02),
                              teal.opacity(0.10)]),
            center: center,
            startRadius: 0,
            endRadius: coreR))
    }

    // MARK: - Animated geometry (per frame)

    private static func drawOrbit(_ ctx: GraphicsContext, size: CGSize, t: TimeInterval, teal: Color) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let minSide = min(size.width, size.height)

        // Orbit path: slightly elliptical, with the mass sped up on one
        // side via a sine warp on the angle (gravity-slingshot feel).
        let period = 1.25                            // one orbit, seconds
        let base = (t.truncatingRemainder(dividingBy: period)) / period * 2 * .pi
        let orbitRX = minSide * 0.40
        let orbitRY = minSide * 0.34

        func point(at phase: Double) -> CGPoint {
            let a = phase + 0.35 * sin(phase)       // non-uniform speed
            return CGPoint(x: center.x + orbitRX * CGFloat(cos(a)),
                           y: center.y + orbitRY * CGFloat(sin(a)))
        }

        // Fading trail behind the mass.
        let trailCount = 7
        for i in stride(from: trailCount, through: 1, by: -1) {
            let phase = base - Double(i) * 0.16
            let p = point(at: phase)
            let fade = 1 - Double(i) / Double(trailCount + 1)
            let r = minSide * 0.05 * CGFloat(fade)
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                             width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(teal.opacity(0.35 * fade)))
        }

        // The orbiting mass: a bright glowing ball.
        let mass = point(at: base)
        let glowR = minSide * 0.13
        ctx.fill(Path(ellipseIn: CGRect(x: mass.x - glowR, y: mass.y - glowR,
                                        width: glowR * 2, height: glowR * 2)),
                 with: .radialGradient(
                    Gradient(colors: [teal.opacity(0.55), .clear]),
                    center: mass, startRadius: 0, endRadius: glowR))

        let ballR = minSide * 0.055
        ctx.fill(Path(ellipseIn: CGRect(x: mass.x - ballR, y: mass.y - ballR,
                                        width: ballR * 2, height: ballR * 2)),
                 with: .radialGradient(
                    Gradient(colors: [.white, teal, teal.opacity(0.9)]),
                    center: CGPoint(x: mass.x - ballR * 0.3,
                                    y: mass.y - ballR * 0.3),
                    startRadius: 0, endRadius: ballR))
    }
}
