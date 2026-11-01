import SwiftUI

// The job half of the Training page: the stage rail, the live progress line
// and the error banner.

/// The five things that happen to your data, in order, and where the job is
/// among them.
struct TrainingPipeline {
    /// `keys` are the backend job stages that light the node up.
    struct Stage: Identifiable {
        let keys: [String]
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    enum StageState { case pending, active, done, failed }

    let stages: [Stage]
    let job: WhisperTrainingJob?

    /// Built from the current selection so the SFT node's technical line
    /// tracks it (each checkpoint size gets its own adapter profile from the
    /// backend).
    @MainActor
    init(_ model: TrainingJobModel) {
        let sft: String
        if let selected = model.selectedTrainingModel, let profile = selected.profileSummary {
            sft = "\(TrainingMethod.label(model.selectedMethod)) · \(profile)"
        } else {
            sft = "LoRA · size-aware profile"
        }
        stages = [
            .init(keys: ["preparing", "dataset"], icon: "waveform",
                  title: "Data", detail: ""),
            .init(keys: ["training"], icon: "slider.horizontal.3",
                  title: "Train", detail: sft),
            .init(keys: ["merging"], icon: "arrow.triangle.merge",
                  title: "Merge", detail: "adapter → full weights"),
            .init(keys: ["converting"], icon: "cpu.fill",
                  title: "Convert", detail: ""),
            .init(keys: ["installing", "installed"], icon: "checkmark.seal.fill",
                  title: "Install", detail: "Dictation model picker"),
        ]
        job = model.job
    }

    /// Index of the stage the job is currently in (5 = everything done).
    var activeIndex: Int {
        guard let job else { return -1 }
        if job.state == "done" { return stages.count }
        guard job.isActive else { return -1 }
        return stages.firstIndex { $0.keys.contains(job.stage) } ?? 0
    }

    /// The stage a failed job stopped in (-1 when it didn't fail / unknown).
    var failedIndex: Int {
        guard let job, job.state == "error", let stage = job.failedStage else { return -1 }
        return stages.firstIndex { $0.keys.contains(stage) } ?? 0
    }

    func state(of index: Int) -> StageState {
        let failed = failedIndex
        if failed >= 0 {
            return index < failed ? .done : index == failed ? .failed : .pending
        }
        let active = activeIndex
        if active >= stages.count || index < active { return .done }
        if index == active { return .active }
        return .pending
    }

    /// True while a run is actually progressing — the only time the rail
    /// animates (idle settings pages must not tick timers).
    var running: Bool {
        job?.isActive == true && activeIndex >= 0 && activeIndex < stages.count
    }
}

/// The five nodes joined by connectors that fill as stages complete.
/// While training runs, the whole rail is driven by one TimelineView:
/// the active node breathes and carries an orbiting arc, and the
/// connector feeding it streams comets — energy visibly flowing into
/// the stage that's working. Idle, it renders once and costs nothing.
struct TrainingStageRail: View {
    let pipeline: TrainingPipeline
    @Environment(\.sliveLayout) private var layout

    private var stages: [TrainingPipeline.Stage] { pipeline.stages }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40, paused: !pipeline.running)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    stageNode(stage, state: pipeline.state(of: index), phase: phase)
                    if index < stages.count - 1 {
                        connector(after: index, phase: phase)
                    }
                }
            }
        }
    }

    private func stageNode(_ stage: TrainingPipeline.Stage, state: TrainingPipeline.StageState,
                           phase: Double) -> some View {
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
                let tint = state == .failed ? SliveTheme.warn : SliveTheme.accent
                Circle()
                    .fill(state == .pending ? SliveTheme.cardFill
                          : tint.opacity(state == .done ? 0.2 : 0.3))
                    .overlay(
                        Circle().strokeBorder(
                            state == .pending ? SliveTheme.pendingStroke
                            : tint.opacity(0.85),
                            lineWidth: 1)
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: state == .done ? "checkmark"
                      : state == .failed ? "xmark" : stage.icon)
                    .font(SliveTheme.iconFont)
                    .foregroundStyle(state == .pending ? SliveTheme.textTertiary : tint)
                    .shadow(color: state == .active ? SliveTheme.accent.opacity(0.8) : .clear,
                            radius: 4)
            }
            .frame(width: 50, height: 50)
            Text(stage.title)
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(state == .failed ? SliveTheme.warn
                                 : state == .pending ? SliveTheme.textSecondary : SliveTheme.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(width: layout == .compact ? 62 : 96)
    }

    /// Connector after stage `index`: dim when pending, solid accent once
    /// crossed — and while its downstream stage is the active one, comets
    /// stream along it toward the work.
    private func connector(after index: Int, phase: Double) -> some View {
        let done = pipeline.state(of: index) == .done
        let flowing = pipeline.running && index == pipeline.activeIndex - 1
        return Canvas { context, size in
            let y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line,
                           with: .color(done ? SliveTheme.accent.opacity(0.55)
                                             : SliveTheme.gridLine),
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
}

/// The running job's progress bar, message, live ETA and output name.
struct TrainingProgressRow: View {
    let job: WhisperTrainingJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: job.progress).tint(SliveTheme.accent)
            HStack(spacing: 6) {
                Text(job.message).sliveCaption()
                if let eta = TrainingJobModel.etaText(job) {
                    Text("· \(eta)")
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.accentText)
                }
                Spacer()
                Text(job.modelName)
                    .font(SliveTheme.mono(10))
                    .foregroundStyle(SliveTheme.textDim)
            }
        }
    }
}

/// Why training didn't start or where it stopped — a real banner, not a
/// caption: Oct 29 a refused start rendered nothing at all.
struct TrainingErrorBanner: View {
    let message: String
    let pipeline: TrainingPipeline
    @ObservedObject var model: TrainingJobModel

    var body: some View {
        let job = pipeline.job
        let failedIndex = pipeline.failedIndex
        let stages = pipeline.stages
        let stopped = job?.state == "error" && job?.error == message
        let stage = failedIndex >= 0 && failedIndex < stages.count ? stages[failedIndex].title : nil
        let title = stopped
            ? "Training stopped\(stage.map { " at \($0)" } ?? "")"
            : "Training didn't start"
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(SliveTheme.iconFont)
                .foregroundStyle(SliveTheme.warn)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SliveTheme.font(12, .semibold))
                    .foregroundStyle(SliveTheme.textPrimary)
                Text(message)
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textMid)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if stopped, let job, job.resumable {
                // Training is the hours-long part; a failure after it keeps
                // the adapter, so finish from where it stopped.
                Button("Resume") { model.resume(job.id) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .tint(SliveTheme.accent)
                    .help("Finish from \(stage ?? "where it stopped") — no retraining")
            }
            Button {
                model.jobError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(SliveTheme.tagBoldFont)
                    .foregroundStyle(SliveTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
                .fill(SliveTheme.warnFill)
                .overlay(RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
                    .strokeBorder(SliveTheme.warnStroke, lineWidth: 1))
        )
    }
}
