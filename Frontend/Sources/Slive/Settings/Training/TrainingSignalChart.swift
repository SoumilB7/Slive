import SwiftUI

// MARK: - Training signal (loss + KL, live)

struct TrainingSignalCard: View {
    let job: WhisperTrainingJob?

    private var metrics: [TrainingMetric] { job?.metrics ?? [] }

    var body: some View {
        SettingsCard("TRAINING SIGNAL") {
            if metrics.count > 1 || job?.isActive == true {
                TrainingSignalChart(metrics: metrics)
                    .frame(height: 150)
                    .padding(10)
                    .innerWell()
                HStack(spacing: 16) {
                    legendEntry(color: SliveTheme.accent, label: "Loss",
                                value: metrics.last.map { String(format: "%.3f", $0.loss) })
                    legendEntry(color: SliveTheme.warnText, label: "Drift",
                                value: metrics.last(where: { $0.kl != nil })?.kl
                                    .map { String(format: "%.4f", $0) })
                    Spacer()
                    if let job, job.totalUpdates > 0 {
                        Text("\(metrics.count)/\(job.totalUpdates)")
                            .font(SliveTheme.mono(10))
                            .foregroundStyle(SliveTheme.textDim)
                    }
                }
            }
        }
    }

    private func legendEntry(color: Color, label: String, value: String?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(SliveTheme.font(10, .semibold))
                .foregroundStyle(SliveTheme.textSecondary)
            if let value {
                Text(value)
                    .font(SliveTheme.mono(10))
                    .foregroundStyle(SliveTheme.textPrimary)
            }
        }
    }
}

// MARK: - Chart

/// Two-series line chart drawn with Canvas (no Charts dependency): CE loss on
/// every update in accent, KL-vs-base samples in orange, each normalised to
/// its own range (the shapes matter, not a shared scale), with faint vertical
/// hairlines at epoch boundaries.
private struct TrainingSignalChart: View {
    let metrics: [TrainingMetric]

    var body: some View {
        Canvas { context, size in
            guard metrics.count > 1 else { return }
            let rect = CGRect(x: 0, y: 4, width: size.width, height: size.height - 8)

            let firstUpdate = Double(metrics.first!.update)
            let lastUpdate = Double(metrics.last!.update)
            let span = max(lastUpdate - firstUpdate, 1)
            func x(_ update: Int) -> CGFloat {
                rect.minX + rect.width * CGFloat((Double(update) - firstUpdate) / span)
            }

            // Epoch boundaries.
            var lastEpoch = metrics.first!.epoch
            for m in metrics where m.epoch != lastEpoch {
                lastEpoch = m.epoch
                let px = x(m.update)
                var line = Path()
                line.move(to: CGPoint(x: px, y: rect.minY))
                line.addLine(to: CGPoint(x: px, y: rect.maxY))
                context.stroke(line, with: .color(SliveTheme.gridLineSoft), lineWidth: 1)
            }

            // Baseline.
            var base = Path()
            base.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            base.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.stroke(base, with: .color(SliveTheme.gridLine), lineWidth: 1)

            drawSeries(metrics.map { ($0.update, $0.loss) },
                       in: rect, x: x, context: &context,
                       color: SliveTheme.accent, lineWidth: 1.6)
            let klPoints = metrics.compactMap { m in m.kl.map { (m.update, $0) } }
            if klPoints.count > 1 {
                drawSeries(klPoints, in: rect, x: x, context: &context,
                           color: SliveTheme.warnText, lineWidth: 1.3)
            }
        }
    }

    /// Normalise a series to its own min…max and stroke it; emphasise the
    /// latest point with a dot.
    private func drawSeries(_ points: [(Int, Double)], in rect: CGRect,
                            x: (Int) -> CGFloat, context: inout GraphicsContext,
                            color: Color, lineWidth: CGFloat) {
        let values = points.map(\.1)
        guard let lo = values.min(), let hi = values.max() else { return }
        let range = max(hi - lo, 1e-6)
        func y(_ value: Double) -> CGFloat {
            rect.maxY - rect.height * CGFloat((value - lo) / range)
        }
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: x(point.0), y: y(point.1))
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
        if let last = points.last {
            let p = CGPoint(x: x(last.0), y: y(last.1))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                         with: .color(color))
        }
    }
}
