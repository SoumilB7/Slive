import SwiftUI

/// The latency ⇄ resources graph: four real configurations plotted by their
/// estimated release→typed latency (X) against what they spend (Y — resident
/// RAM in accent, energy behavior in orange). Click a point to LIVE that
/// point: the tier applies immediately, and the readout below itemizes
/// exactly what the chosen latency costs. Estimates track the selected
/// dictation model, so the chart tells the truth for Balanced, not for a
/// demo-sized model.
struct LatencyGraphView: View {
    @ObservedObject var settings: Settings

    private var tiers: [SpeedTier] { SpeedTier.allCases }
    /// Measured on this machine when calibration exists, else the estimate.
    private var effective: (factor: Double, measured: Bool) {
        SpeedTier.effectiveFactor(
            measuredRate: TranscriptionModel.measuredRate(for: settings.whisperModel),
            model: settings.whisperModel)
    }
    private var modelFactor: Double { effective.factor }
    private var residentGB: Double { SpeedTier.residentGB(for: settings.whisperModel) }
    private var latencies: [Double] { tiers.map { $0.estimatedLatency(modelFactor: modelFactor) } }
    private var selected: SpeedTier { settings.resolvedSpeedTier }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chart
                .frame(height: 162)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .innerWell()

            HStack(spacing: 14) {
                legendDot(color: SliveTheme.accent, label: "Model RAM")
                legendDot(color: .orange.opacity(0.9), label: "Energy")
                legendDot(color: .yellow.opacity(0.85), label: "Battery")
                Spacer()
                // The machine checker behind the "maximum reach" tag: what
                // this Mac is, and whether the numbers are measured or guessed.
                Text("\(MachineProfile.summary) · \(effective.measured ? "measured on this Mac" : "estimate — calibrates as you dictate")")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textTertiary)
            }

            // The receipt: what the clicked latency costs, itemized.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(selected.costLines(modelResidentGB: residentGB,
                                           batteryWh: MachineProfile.batteryWh), id: \.0) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(line.0)
                            .font(SliveTheme.font(10, .semibold))
                            .foregroundStyle(SliveTheme.textSecondary)
                            .frame(width: 92, alignment: .leading)
                        Text(line.1)
                            .font(SliveTheme.mono(10.5))
                            .foregroundStyle(SliveTheme.textMid)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .innerWell()
        }
    }

    // MARK: - Chart

    private var chart: some View {
        GeometryReader { geo in
            let xs = Self.xPositions(latencies: latencies, width: geo.size.width)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(in: &ctx, size: size, xs: xs)
                }
                // One generous hit column per tier — a graph you can't easily
                // click is a diagram, not a control.
                ForEach(Array(tiers.enumerated()), id: \.element.id) { index, tier in
                    let lo = index == 0 ? 0 : (xs[index - 1] + xs[index]) / 2
                    let hi = index == tiers.count - 1 ? geo.size.width : (xs[index] + xs[index + 1]) / 2
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: max(hi - lo, 8), height: geo.size.height)
                        .offset(x: lo)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                settings.speedTier = tier.rawValue
                            }
                            TranscriptionModel.shared.applySpeedTier()
                        }
                        .help("\(tier.label) — ≈\(Self.ms(latencies[index]))")
                }
            }
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, xs: [CGFloat]) {
        let plotTop: CGFloat = 28           // tag zone lives above the plot
        let plotBottom = size.height - 30   // room for the tier labels
        let plotHeight = plotBottom - plotTop

        func y(_ fraction: Double) -> CGFloat {
            plotBottom - plotHeight * CGFloat(min(max(fraction, 0), 1))
        }

        // Series, each normalised to its own scale (shape is the message).
        let maxRam = max(residentGB, 0.1)
        let ramFractions = tiers.map { $0.estimatedRamGB(modelResidentGB: residentGB) / maxRam }
        let energyFractions = tiers.map(\.energyIndex)

        // Baseline.
        var base = Path()
        base.move(to: CGPoint(x: 0, y: plotBottom))
        base.addLine(to: CGPoint(x: size.width, y: plotBottom))
        ctx.stroke(base, with: .color(.white.opacity(0.12)), lineWidth: 1)

        // The selector: a big test-tube shape (straight sides, fully rounded
        // bottom) parked over the chosen column — it wraps the points AND the
        // labels below, reading as "this is where my dial sits".
        let sel = selected.rawValue
        let tubeWidth = min(60, max(44, size.width / CGFloat(tiers.count) * 0.55))
        let tubeX = min(max(xs[sel] - tubeWidth / 2, 2), size.width - tubeWidth - 2)
        let tubeRect = CGRect(x: tubeX, y: plotTop - 8,
                              width: tubeWidth, height: (size.height - 2) - (plotTop - 8))
        let tube = Path(roundedRect: tubeRect,
                        cornerRadii: RectangleCornerRadii(
                            topLeading: 9, bottomLeading: tubeWidth / 2,
                            bottomTrailing: tubeWidth / 2, topTrailing: 9))
        ctx.fill(tube, with: .color(SliveTheme.accent.opacity(0.10)))
        ctx.stroke(tube, with: .color(SliveTheme.accent.opacity(0.45)), lineWidth: 1.2)

        // RAM area + line (accent).
        var area = Path()
        area.move(to: CGPoint(x: xs[0], y: plotBottom))
        for (i, x) in xs.enumerated() { area.addLine(to: CGPoint(x: x, y: y(ramFractions[i]))) }
        area.addLine(to: CGPoint(x: xs[xs.count - 1], y: plotBottom))
        area.closeSubpath()
        ctx.fill(area, with: .color(SliveTheme.accent.opacity(0.08)))
        drawSeries(&ctx, xs: xs, ys: ramFractions.map(y),
                   color: SliveTheme.accent, selectedIndex: sel)

        // Energy line (orange) — per-dictation effort.
        drawSeries(&ctx, xs: xs, ys: energyFractions.map(y),
                   color: .orange.opacity(0.9), selectedIndex: sel)

        // Battery line (yellow) — the ongoing drain of keeping tensors hot.
        let batteryFractions = tiers.map(\.batteryIndex)
        drawSeries(&ctx, xs: xs, ys: batteryFractions.map(y),
                   color: .yellow.opacity(0.85), selectedIndex: sel)

        // The fastest point carries this hardware's ceiling claim — backed by
        // MachineProfile and the measured decode rate, both shown in the
        // caption row beneath the chart.
        let tag = Text("this machine's maximum reach")
            .font(SliveTheme.font(8.5, .semibold))
            .foregroundColor(SliveTheme.accent)
        let resolvedTag = ctx.resolve(tag)
        let tagSize = resolvedTag.measure(in: CGSize(width: 220, height: 16))
        let tagRect = CGRect(
            x: min(max(xs[0] - 8, 2), size.width - tagSize.width - 14),
            y: 4, width: tagSize.width + 12, height: tagSize.height + 5)
        ctx.fill(Path(roundedRect: tagRect, cornerRadius: tagRect.height / 2),
                 with: .color(SliveTheme.accent.opacity(0.12)))
        ctx.stroke(Path(roundedRect: tagRect, cornerRadius: tagRect.height / 2),
                   with: .color(SliveTheme.accent.opacity(0.3)), lineWidth: 0.8)
        ctx.draw(resolvedTag, at: CGPoint(x: tagRect.midX, y: tagRect.midY))
        var lead = Path()
        lead.move(to: CGPoint(x: xs[0], y: tagRect.maxY + 1))
        lead.addLine(to: CGPoint(x: xs[0], y: plotTop - 2))
        ctx.stroke(lead, with: .color(SliveTheme.accent.opacity(0.3)), lineWidth: 1)

        // Tier labels along the X axis: latency first (it IS the axis), name under.
        for (i, tier) in tiers.enumerated() {
            let isSel = i == sel
            let latency = Text(Self.ms(latencies[i]))
                .font(SliveTheme.mono(9.5))
                .foregroundColor(isSel ? SliveTheme.accent : .white.opacity(0.55))
            ctx.draw(ctx.resolve(latency), at: CGPoint(x: xs[i], y: plotBottom + 9))
            let name = Text(tier.label)
                .font(SliveTheme.font(9, isSel ? .bold : .medium))
                .foregroundColor(isSel ? .white.opacity(0.9) : .white.opacity(0.4))
            ctx.draw(ctx.resolve(name), at: CGPoint(x: xs[i], y: plotBottom + 21))
        }
    }

    private func drawSeries(_ ctx: inout GraphicsContext, xs: [CGFloat], ys: [CGFloat],
                            color: Color, selectedIndex: Int) {
        var line = Path()
        for (i, x) in xs.enumerated() {
            let p = CGPoint(x: x, y: ys[i])
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(color.opacity(0.8)), lineWidth: 1.5)
        for (i, x) in xs.enumerated() {
            let p = CGPoint(x: x, y: ys[i])
            let r: CGFloat = i == selectedIndex ? 4 : 2.5
            if i == selectedIndex {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                         with: .color(color.opacity(0.18)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(color))
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(SliveTheme.font(10, .semibold))
                .foregroundStyle(SliveTheme.textSecondary)
        }
    }

    // MARK: - Pure layout math (self-tested)

    /// X position per tier, spaced by actual estimated latency so the axis is
    /// honest — equal visual gaps would lie about how close the tiers are.
    static func xPositions(latencies: [Double], width: CGFloat,
                           inset: CGFloat = 26) -> [CGFloat] {
        guard let lo = latencies.min(), let hi = latencies.max(), hi > lo else {
            return latencies.enumerated().map { i, _ in
                inset + (width - 2 * inset) * CGFloat(i) / CGFloat(max(latencies.count - 1, 1))
            }
        }
        let span = width - 2 * inset
        return latencies.map { inset + span * CGFloat(($0 - lo) / (hi - lo)) }
    }

    static func ms(_ seconds: Double) -> String {
        seconds < 1 ? "~\(Int((seconds * 1000).rounded()))ms"
                    : String(format: "~%.1fs", seconds)
    }
}
