import AppKit
import SwiftUI

extension SettingsPageID {
    static let training = SettingsPageID("training")
}

extension SettingsPageSpec {
    static let training = SettingsPageSpec(
        id: .training, title: "Training", icon: "waveform.path.ecg", section: .lab,
        requires: \.training,
        width: .table
    ) { ctx in
        AnyView(TrainingSettingsView(
            transcription: ctx.env.transcription, labelRun: ctx.env.labelRun,
            client: ctx.env.trainingClient, openData: { ctx.open(.data) }))
    }
}

/// The Training page: the fine-tuning pipeline made visible. A stage rail
/// shows exactly what happens to your data (dataset → LoRA → merge → ANE
/// convert → install), a live chart plots the two numbers that matter while
/// it runs (CE loss on your corrections, KL drift from stock Balanced), and
/// the output card says what lands where. Data lives next door on the Data
/// page — this page burns it.
struct TrainingSettingsView: View {
    @ObservedObject private var transcription: TranscriptionModel
    /// A ground-truth run in progress (started on the Data page).
    private let labelRun: LabelRun
    @StateObject private var model: TrainingJobModel
    @Environment(\.sliveLayout) private var layout
    /// Navigates to the Data page (capture + ground truth live there).
    private let openData: () -> Void

    init(transcription: TranscriptionModel, labelRun: LabelRun,
         client: TrainingJobClient, openData: @escaping () -> Void = {}) {
        _transcription = ObservedObject(wrappedValue: transcription)
        self.labelRun = labelRun
        _model = StateObject(wrappedValue: TrainingJobModel(
            client: client, onModelsChanged: { transcription.refreshCustomModels() }))
        self.openData = openData
    }

    private var metrics: [TrainingMetric] { model.job?.metrics ?? [] }

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            pipelineCard
            if metrics.count > 1 || model.job?.isActive == true { TrainingSignalCard(job: model.job) }
            outputCard
        }
        .frame(maxWidth: layout == .compact ? .infinity : SliveTheme.formWidth * 1.35)
        .onAppear {
            transcription.refreshCustomModels()
            model.refresh()
        }
        .onDisappear { model.stopPolling() }
    }

    // MARK: - Pipeline (the procedure, as a live diagram)

    private var pipelineCard: some View {
        let pipeline = TrainingPipeline(model)
        return SettingsCard("NEW MODEL", trailing: {
            if model.checking { ProgressView().controlSize(.small) }
        }) {
            // 1. Can I train yet? — the first question, answered first.
            TrainingReadinessSection(readiness: model.readiness, openData: openData)
            TrainingLabelRunStatus(labelRun: labelRun, openData: openData)

            CardDivider()

            // 2. What to train.
            TrainingChoicesRow(model: model)
            TrainingAdvancedDisclosure(model: model)

            // 3. The journey your data takes — only once a run exists.
            if model.job != nil {
                TrainingStageRail(pipeline: pipeline)
                    .padding(.vertical, 6)
            }

            if let job = model.job, job.isActive {
                TrainingProgressRow(job: job)
            }

            CardDivider()

            // 4. Go.
            TrainingActionRow(model: model)

            if let jobError = model.jobError {
                TrainingErrorBanner(message: jobError, pipeline: pipeline, model: model)
            }
        }
    }

    // MARK: - Output (what you get, where it lives, how it runs)

    private var outputCard: some View {
        SettingsCard("YOUR MODELS") {
            if transcription.customModels.isEmpty {
                Text("No models yet.").sliveCaption()
            } else {
                ForEach(transcription.customModels) { custom in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(SliveTheme.smallFont)
                            .foregroundStyle(SliveTheme.ok)
                        Text(custom.displayName)
                            .font(SliveTheme.mono(11))
                            .foregroundStyle(SliveTheme.textPrimary)
                        if custom.id == model.job?.modelName, let eval = model.job?.evaluation {
                            Text(eval.summary).sliveCaption()
                        }
                        Spacer()
                    }
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.open(CustomWhisperModelRegistry.root)
            }
            .buttonStyle(.plain)
            .font(SliveTheme.font(11, .semibold))
            .foregroundStyle(SliveTheme.textDim)
        }
    }
}
