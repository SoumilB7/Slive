import SwiftUI

// The form half of the Training page: can I train yet, what to train, go.

/// "Can I train yet?" — shown as progress toward the two gates when you're
/// not there, and a green all-clear once you are. Leads the card so the
/// answer is the first thing you see, not the last.
struct TrainingReadinessSection: View {
    let readiness: TrainingReadiness?
    let openData: () -> Void

    var body: some View {
        if let readiness {
            if readiness.ready {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(SliveTheme.iconMedium)
                        .foregroundStyle(SliveTheme.ok)
                    Text("Ready to train")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.ok)
                    Text("· \(readiness.eligibleCount) recordings · \(String(format: "%.1f", readiness.eligibleAudioMinutes)) min")
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.textTertiary)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    readinessBar(
                        label: "Recordings",
                        valueText: "\(readiness.eligibleCount) of \(readiness.requiredSamples)",
                        fraction: readiness.requiredSamples <= 0 ? 1
                            : Double(readiness.eligibleCount) / Double(readiness.requiredSamples),
                        met: readiness.eligibleCount >= readiness.requiredSamples)
                    readinessBar(
                        label: "Speech",
                        valueText: String(format: "%.1f of %.0f min",
                                          readiness.eligibleAudioMinutes,
                                          max(readiness.requiredAudioMinutes, 0)),
                        fraction: readiness.requiredAudioMinutes <= 0 ? 1
                            : min(1, readiness.eligibleAudioMinutes / readiness.requiredAudioMinutes),
                        met: readiness.requiredAudioMinutes <= 0
                            || readiness.eligibleAudioMinutes >= readiness.requiredAudioMinutes)
                    HStack(alignment: .top, spacing: 10) {
                        Spacer(minLength: 0)
                        Button {
                            openData()
                        } label: {
                            Label("Add data", systemImage: "arrow.right")
                                .font(SliveTheme.font(11, .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(SliveTheme.accent)
                        .fixedSize()
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").sliveCaption()
            }
        }
    }

    /// One gate as a labelled progress bar — clearer than a bare "3 / 50".
    private func readinessBar(label: String, valueText: String,
                              fraction: Double, met: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(SliveTheme.font(12, .semibold))
                    .foregroundStyle(SliveTheme.textPrimary)
                Spacer()
                Text(valueText)
                    .font(SliveTheme.mono(11))
                    .foregroundStyle(met ? SliveTheme.ok : SliveTheme.warn)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SliveTheme.trackFillSlim).frame(height: 5)
                    Capsule()
                        .fill(met ? SliveTheme.ok : SliveTheme.accent)
                        .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, fraction)))),
                               height: 5)
                }
                .frame(height: 5)
            }
            .frame(height: 5)
        }
    }
}

/// While the Data page is labeling, say so here — fresh labels are what
/// moves the readiness bars, so "wait for it" is worth knowing.
struct TrainingLabelRunStatus: View {
    @ObservedObject var labelRun: LabelRun
    let openData: () -> Void

    var body: some View {
        if labelRun.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Labeling · \(labelRun.done.formatted())/\(labelRun.total.formatted())")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textSecondary)
                Spacer(minLength: 0)
                Button("View", action: openData)
                    .buttonStyle(.plain)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.accent)
            }
        }
    }
}

/// The two decisions kept on the face: which checkpoint family, which method.
struct TrainingChoicesRow: View {
    @ObservedObject var model: TrainingJobModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Base model")
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(SliveTheme.textSecondary)
            Picker("", selection: $model.selectedModel) {
                ForEach(model.trainingModels) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .disabled(model.job?.isActive == true || model.trainingModels.isEmpty)

            Text("Method")
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(SliveTheme.textSecondary)
            Picker("", selection: $model.selectedMethod) {
                // QLoRA needs a CUDA host; this app trains on the Mac.
                Text("Hybrid").tag(TrainingMethod.hybrid)
                Text("Decoder only").tag(TrainingMethod.decoder)
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .disabled(model.job?.isActive == true)
            .help(model.selectedMethod == TrainingMethod.decoder
                  ? "3× faster · no accent" : "Best quality · ~6 GB")
            Spacer(minLength: 0)
        }
    }
}

// MARK: Advanced (progressive disclosure — collapsed by default)

/// The profile breakdown, RAM ceiling, time estimate, and output name —
/// everything that used to crowd the face, one tap away.
struct TrainingAdvancedDisclosure: View {
    @ObservedObject var model: TrainingJobModel
    /// The small print (profile, RAM, time, name) is tucked one tap away.
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(SliveTheme.labelFont)
                        .foregroundStyle(SliveTheme.accentText)
                    Text("Advanced")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(SliveTheme.textSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(SliveTheme.tagBoldFont)
                        .foregroundStyle(SliveTheme.textTertiary)
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                advancedBody.padding(.top, 12)
            }
        }
    }

    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Max RAM.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Max RAM")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(SliveTheme.textSecondary)
                    Slider(value: $model.maxRamGB, in: 2...32, step: 1)
                        .frame(maxWidth: 220)
                        .disabled(model.job?.isActive == true)
                    Text("\(Int(model.maxRamGB)) GB")
                        .font(SliveTheme.mono(11))
                        .foregroundStyle(SliveTheme.accent)
                        .frame(width: 42, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .help("Training stops above this")
                if let selected = model.selectedTrainingModel, model.maxRamGB < selected.loraRamGB {
                    Text("Below the \(Int(selected.loraRamGB)) GB recommended.")
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.warn)
                }
            }

            Divider().overlay(SliveTheme.divider)

            // Name.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Name")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(SliveTheme.textSecondary)
                    TextField("\(model.selectedModel == TrainingJobModel.defaultSourceModel ? "balanced" : model.selectedModel.replacingOccurrences(of: ".", with: "-"))-ft-<date>-<time>", text: $model.customName)
                        .textFieldStyle(.roundedBorder)
                        .font(SliveTheme.monoSmall)
                        .frame(maxWidth: 260)
                        .disabled(model.job?.isActive == true)
                }
            }
        }
        .padding(10)
        .innerWell()
    }
}

/// The action, anchored at the bottom of the card where actions belong.
struct TrainingActionRow: View {
    @ObservedObject var model: TrainingJobModel

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if let estimate = model.estimatedMinutes {
                Text(TrainingJobModel.timeText(estimate))
                    .font(SliveTheme.mono(11))
                    .foregroundStyle(SliveTheme.accent)
            }
            Button {
                model.start()
            } label: {
                Label(model.job?.isActive == true ? "Training…" : "Train",
                      systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.borderedProminent)
            .tint(SliveTheme.accent)
            .controlSize(.small)
            .disabled(model.readiness?.ready != true || model.job?.isActive == true)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(SliveTheme.labelFont)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SliveTheme.accent)
            .help("Refresh")
        }
    }
}
