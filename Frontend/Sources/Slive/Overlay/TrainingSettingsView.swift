import AppKit
import SwiftUI

/// The Training page: the fine-tuning pipeline made visible. A stage rail
/// shows exactly what happens to your data (dataset → LoRA → merge → ANE
/// convert → install), a live chart plots the two numbers that matter while
/// it runs (CE loss on your corrections, KL drift from stock Balanced), and
/// the output card says what lands where. Data lives next door on the Data
/// page — this page burns it.
struct TrainingSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var transcription = TranscriptionModel.shared
    @Environment(\.sliveLayout) private var layout
    /// Navigates to the Data page (capture + ground truth live there).
    var openData: () -> Void = {}

    @State private var readiness: TrainingReadiness?
    @State private var job: WhisperTrainingJob?
    @State private var jobError: String?
    @State private var checking = false

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            pipelineCard
            signalCard
            outputCard
        }
        .frame(maxWidth: layout == .compact ? .infinity : SliveTheme.formWidth * 1.35)
        .onAppear {
            transcription.refreshCustomModels()
            refresh()
        }
    }

    // MARK: - Pipeline (the procedure, as a live diagram)

    /// The five things that happen to your data, in order. `keys` are the
    /// backend job stages that light the node up.
    private struct StageSpec: Identifiable {
        let keys: [String]
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let stages: [StageSpec] = [
        .init(keys: ["preparing", "dataset"], icon: "waveform",
              title: "Dataset", detail: "your corrected dictations"),
        .init(keys: ["training"], icon: "slider.horizontal.3",
              title: "LoRA fine-tune", detail: "r=4 · q/v proj · 3 epochs"),
        .init(keys: ["merging"], icon: "arrow.triangle.merge",
              title: "Merge", detail: "adapter → full weights"),
        .init(keys: ["converting"], icon: "cpu.fill",
              title: "ANE convert", detail: "CoreML · WhisperKit"),
        .init(keys: ["installing", "installed"], icon: "checkmark.seal.fill",
              title: "Install", detail: "Dictation model picker"),
    ]

    private enum StageState { case pending, active, done }

    /// Index of the stage the job is currently in (5 = everything done).
    private var activeIndex: Int {
        guard let job else { return -1 }
        if job.state == "done" { return stages.count }
        guard job.isActive else { return -1 }
        return stages.firstIndex { $0.keys.contains(job.stage) } ?? 0
    }

    private func state(of index: Int) -> StageState {
        let active = activeIndex
        if active >= stages.count || index < active { return .done }
        if index == active { return .active }
        return .pending
    }

    private var pipelineCard: some View {
        SettingsCard("FINE-TUNE PIPELINE", trailing: {
            if checking { ProgressView().controlSize(.small) }
        }) {
            Text("Balanced Whisper learns your voice from the recordings you corrected on the Data page. Everything runs on this Mac — nothing leaves it.")
                .sliveCaption()

            stageRail
                .padding(.vertical, 6)

            if let job, job.isActive {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: job.progress).tint(SliveTheme.accent)
                    HStack {
                        Text(job.message).sliveCaption()
                        Spacer()
                        Text(job.modelName)
                            .font(SliveTheme.mono(10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }

            CardDivider()

            readinessRow

            if let jobError {
                Text(jobError)
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// True while a run is actually progressing — the only time the rail
    /// animates (idle settings pages must not tick timers).
    private var running: Bool {
        job?.isActive == true && activeIndex >= 0 && activeIndex < stages.count
    }

    /// The five nodes joined by connectors that fill as stages complete.
    /// While training runs, the whole rail is driven by one TimelineView:
    /// the active node breathes and carries an orbiting arc, and the
    /// connector feeding it streams comets — energy visibly flowing into
    /// the stage that's working. Idle, it renders once and costs nothing.
    private var stageRail: some View {
        TimelineView(.animation(minimumInterval: 1 / 40, paused: !running)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    stageNode(stage, state: state(of: index), phase: phase)
                    if index < stages.count - 1 {
                        connector(after: index, phase: phase)
                    }
                }
            }
        }
    }

    private func stageNode(_ stage: StageSpec, state: StageState, phase: Double) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if state == .active {
                    // Breathing halo — soft accent bloom expanding and fading.
                    let breathe = 0.5 + 0.5 * sin(phase * 2.2)
                    Circle()
                        .fill(SliveTheme.accent.opacity(0.10 + 0.10 * breathe))
                        .frame(width: 40 + 8 * breathe, height: 40 + 8 * breathe)
                        .blur(radius: 3)
                    Circle()
                        .strokeBorder(SliveTheme.accent.opacity(0.35 - 0.2 * breathe), lineWidth: 1)
                        .frame(width: 38 + 9 * breathe, height: 38 + 9 * breathe)
                    // Orbiting arc — the working indicator, one slow revolution.
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(SliveTheme.accent.opacity(0.9),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 42, height: 42)
                        .rotationEffect(.radians(phase * 1.7))
                }
                Circle()
                    .fill(state == .pending ? Color.white.opacity(0.05)
                          : SliveTheme.accent.opacity(state == .done ? 0.2 : 0.3))
                    .overlay(
                        Circle().strokeBorder(
                            state == .pending ? Color.white.opacity(0.15)
                            : SliveTheme.accent.opacity(0.85),
                            lineWidth: 1)
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: state == .done ? "checkmark" : stage.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state == .pending ? Color.white.opacity(0.35) : SliveTheme.accent)
                    .shadow(color: state == .active ? SliveTheme.accent.opacity(0.8) : .clear,
                            radius: 4)
            }
            .frame(width: 50, height: 50)
            Text(stage.title)
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(state == .pending ? SliveTheme.textSecondary : SliveTheme.textPrimary)
                .multilineTextAlignment(.center)
            if layout != .compact {
                Text(stage.detail)
                    .font(SliveTheme.mono(9))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: layout == .compact ? 62 : 96)
    }

    /// Connector after stage `index`: dim when pending, solid accent once
    /// crossed — and while its downstream stage is the active one, comets
    /// stream along it toward the work.
    private func connector(after index: Int, phase: Double) -> some View {
        let done = state(of: index) == .done
        let flowing = running && index == activeIndex - 1
        return Canvas { context, size in
            let y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line,
                           with: .color(done ? SliveTheme.accent.opacity(0.55)
                                             : .white.opacity(0.12)),
                           lineWidth: 2)
            guard flowing, size.width > 16 else { return }
            // Two staggered comets with fading tails, travelling into the
            // active stage.
            for lane in 0..<2 {
                let t = (phase * 0.42 + Double(lane) * 0.5)
                    .truncatingRemainder(dividingBy: 1)
                let head = size.width * CGFloat(t)
                for tail in 0..<5 {
                    let x = head - CGFloat(tail) * 5
                    guard x > 0 else { continue }
                    let fade = 1 - Double(tail) / 5
                    let radius = 2.2 - CGFloat(tail) * 0.35
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(SliveTheme.accent.opacity(0.9 * fade * fade)))
                }
            }
        }
        .frame(height: 8)
        .frame(maxWidth: .infinity)
        .padding(.top, 21)   // centre on the 50pt node stack (circle centre 25)
        .padding(.horizontal, 2)
    }

    private var readinessRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let readiness {
                    // Both gates, each with its own verdict color — training
                    // unlocks only when the two are green together.
                    gatePill(
                        met: readiness.eligibleCount >= readiness.requiredSamples,
                        text: "\(readiness.eligibleCount) / \(readiness.requiredSamples) recordings")
                    gatePill(
                        met: readiness.requiredAudioMinutes <= 0
                            || readiness.eligibleAudioMinutes >= readiness.requiredAudioMinutes,
                        text: String(format: "%.1f / %.0f min audio",
                                     readiness.eligibleAudioMinutes,
                                     max(readiness.requiredAudioMinutes, 0)))
                    Spacer(minLength: 0)
                    if !readiness.ready {
                        Button("Open Data") { openData() }
                            .buttonStyle(.plain)
                            .font(SliveTheme.font(11, .semibold))
                            .foregroundStyle(SliveTheme.accent)
                    }
                } else {
                    Spacer(minLength: 0)
                }

                Button {
                    start()
                } label: {
                    Label(job?.isActive == true ? "Training…" : "Train",
                          systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.borderedProminent)
                .tint(SliveTheme.accent)
                .controlSize(.small)
                .disabled(readiness?.ready != true || job?.isActive == true)

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SliveTheme.accent)
                .help("Refresh readiness and job state")
            }

            if let readiness, !readiness.ready {
                Text("Training unlocks at \(readiness.requiredSamples) well-populated recordings — valid audio with a correction of 3+ words — and \(Int(max(readiness.requiredAudioMinutes, 1))) minutes of total speech.")
                    .sliveCaption()
            }
        }
    }

    private func gatePill(met: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10, weight: .semibold))
            Text(text).font(SliveTheme.mono(11))
        }
        .foregroundStyle(met ? Color.green : .orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(.white.opacity(0.05))
                .overlay(Capsule().strokeBorder((met ? Color.green : .orange).opacity(0.25),
                                                lineWidth: 0.8))
        )
    }

    // MARK: - Training signal (loss + KL, live)

    private var metrics: [TrainingMetric] { job?.metrics ?? [] }

    private var signalCard: some View {
        SettingsCard("TRAINING SIGNAL") {
            if metrics.count > 1 {
                TrainingSignalChart(metrics: metrics)
                    .frame(height: 150)
                    .padding(10)
                    .innerWell()
                HStack(spacing: 16) {
                    legendEntry(color: SliveTheme.accent, label: "CE loss",
                                value: metrics.last.map { String(format: "%.3f", $0.loss) })
                    legendEntry(color: .orange.opacity(0.9), label: "KL vs stock",
                                value: metrics.last(where: { $0.kl != nil })?.kl
                                    .map { String(format: "%.4f", $0) })
                    Spacer()
                    if let job, job.totalUpdates > 0 {
                        Text("update \(metrics.count)/\(job.totalUpdates)")
                            .font(SliveTheme.mono(10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            } else {
                // What the two curves will mean, before there's anything to plot.
                VStack(alignment: .leading, spacing: 8) {
                    legendExplainer(color: SliveTheme.accent, title: "CE loss",
                                    text: "How closely the model matches your corrected transcripts — should fall as it learns your voice.")
                    legendExplainer(color: .orange.opacity(0.9), title: "KL divergence vs stock Balanced",
                                    text: "How far the adapted model drifts from the original, in nats per token. Staying low means it keeps its general accuracy while picking up your speech.")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .innerWell()
                Text("Charts live once a training run starts.")
                    .sliveCaption()
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

    private func legendExplainer(color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.textPrimary)
                Text(text).sliveCaption()
            }
        }
    }

    // MARK: - Output (what you get, where it lives, how it runs)

    private var outputCard: some View {
        SettingsCard("OUTPUT MODEL") {
            infoRow("Base", "whisper-large-v3 (Balanced)")
            infoRow("Name", job?.modelName ?? "balenced-ft-<date>-<time>")
            infoRow("Runs on", "Neural Engine — compiled .mlmodelc, same serving path as stock models")
            infoRow("Stored in", "~/Library/Application Support/Slive/Models/Custom")

            CardDivider()

            if transcription.customModels.isEmpty {
                Text("No personal models yet — the first finished run appears here and in the Dictation model picker.")
                    .sliveCaption()
            } else {
                ForEach(transcription.customModels) { model in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text(model.displayName)
                            .font(SliveTheme.mono(11))
                            .foregroundStyle(SliveTheme.textPrimary)
                        Spacer()
                        Text("in the Dictation picker")
                            .font(SliveTheme.captionFont)
                            .foregroundStyle(SliveTheme.textTertiary)
                    }
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(SliveTheme.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(SliveTheme.mono(11))
                .foregroundStyle(SliveTheme.textMid)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Job state machine

    private func refresh() {
        guard !checking else { return }
        checking = true
        jobError = nil
        Task { @MainActor in
            defer { checking = false }
            do {
                async let ready = TrainingClient().readiness()
                async let latest = TrainingClient().latest()
                readiness = try await ready
                job = try await latest
                if let job, job.isActive { poll(job.id) }
                if job?.state == "done" { transcription.refreshCustomModels() }
                if job?.state == "error" { jobError = job?.error }
            } catch {
                jobError = error.localizedDescription
            }
        }
    }

    private func start() {
        jobError = nil
        Task { @MainActor in
            do {
                let started = try await TrainingClient().start()
                job = started
                poll(started.id)
            } catch {
                jobError = error.localizedDescription
                refresh()
            }
        }
    }

    private func poll(_ id: String) {
        Task { @MainActor in
            while true {
                do {
                    let latest = try await TrainingClient().status(id: id)
                    job = latest
                    if !latest.isActive {
                        if latest.state == "done" {
                            transcription.refreshCustomModels()
                            readiness = try? await TrainingClient().readiness()
                        } else if let error = latest.error {
                            jobError = error
                        }
                        return
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    jobError = error.localizedDescription
                    return
                }
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
                context.stroke(line, with: .color(.white.opacity(0.1)), lineWidth: 1)
            }

            // Baseline.
            var base = Path()
            base.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            base.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.stroke(base, with: .color(.white.opacity(0.12)), lineWidth: 1)

            drawSeries(metrics.map { ($0.update, $0.loss) },
                       in: rect, x: x, context: &context,
                       color: SliveTheme.accent, lineWidth: 1.6)
            let klPoints = metrics.compactMap { m in m.kl.map { (m.update, $0) } }
            if klPoints.count > 1 {
                drawSeries(klPoints, in: rect, x: x, context: &context,
                           color: .orange.opacity(0.9), lineWidth: 1.3)
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
