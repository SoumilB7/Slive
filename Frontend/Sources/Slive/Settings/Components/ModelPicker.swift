import SwiftUI

// The transcription model picker, shared by General, Live typing and the
// ground-truth judge.

/// Live download/prepare status + action for one model. minHeight keeps state
/// changes from reflowing the card.
struct ModelStatusRow: View {
    @ObservedObject var transcription: TranscriptionModel
    let model: String

    var body: some View {
        HStack(spacing: 10) {
            switch transcription.status(for: model) {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SliveTheme.ok)
                Text("Ready").foregroundStyle(SliveTheme.textBody)
                Spacer()
                Button("Re-download") { Task { await transcription.redownload(model) } }
                    .buttonStyle(.plain)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.textDim)
            case .notDownloaded:
                Image(systemName: "arrow.down.circle").foregroundStyle(SliveTheme.accent)
                Text("Not downloaded").foregroundStyle(SliveTheme.textSoft)
                Spacer()
                Button("Download") { Task { await transcription.download(model) } }
                    .buttonStyle(.borderedProminent).tint(SliveTheme.accent).controlSize(.small)
            case .downloading(let p):
                ProgressView(value: p).frame(maxWidth: .infinity)
                Text("\(Int(p * 100))%")
                    .font(SliveTheme.mono(12))
                    .foregroundStyle(SliveTheme.accent)
                    .fixedSize()
            case .preparing(let stage):
                ProgressView().controlSize(.small)
                Text("\(stage)…").foregroundStyle(SliveTheme.textSoft)
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SliveTheme.warn)
                Text(e).foregroundStyle(SliveTheme.warnText).lineLimit(2)
                Spacer()
                Button("Re-download") { Task { await transcription.redownload(model) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(SliveTheme.font(12))
        .frame(minHeight: 24)
    }
}

/// A full model card: picker + detail, live status row, footnote. Used by both
/// Dictation (whisperModel) and Continuous (continuousModel).
struct ModelPickerCard: View {
    let title: String
    @Binding var model: String
    let transcription: TranscriptionModel
    /// Tooltip on the picker.
    var help: String = ""
    /// Which catalog models it offers.
    let use: ModelUse
    /// Offer the large-v3 turbo download while on tiny/base (dictation card).
    var suggestBalanced = false

    var body: some View {
        SettingsCard(title) {
            ModelPickerRows(model: $model, transcription: transcription, use: use)
                .help(help)
            if suggestBalanced { BalancedSuggestion(transcription: transcription, model: $model) }
        }
    }
}

/// A fresh install dictates on the bundled tiny.en, which is far less
/// accurate. Point straight at large-v3 turbo ("Balanced") — not the
/// in-between sizes. The pick switches only once the download finished — a
/// failed or partial one never leaves dictation pointed at a model that
/// can't load; tiny keeps serving until turbo is ready.
struct BalancedSuggestion: View {
    @ObservedObject var transcription: TranscriptionModel
    @Binding var model: String
    @AppStorage("balancedSuggestionDismissed") private var dismissed = false
    /// Whether turbo is on disk — checked when the card appears and when
    /// turbo's status moves, never from `body`: that check reads the disk,
    /// and anything `body` calls must stay cheap and side-effect free
    /// (Nov 13: it once republished on every read and froze fresh installs).
    /// Starts false so the card appears and runs its first check; a turbo
    /// already on disk hides it before it's drawn.
    @State private var onDisk = false
    static let balanced = ModelCatalog.balanced

    var body: some View {
        if ["tiny.en", "base.en"].contains(model), !dismissed, !onDisk {
            suggestion
                .onAppear(perform: recheck)
                .onChange(of: transcription.status(for: Self.balanced)) { _, _ in recheck() }
        }
    }

    private func recheck() {
        let disk = transcription.isDownloaded(Self.balanced)
        if disk != onDisk { onDisk = disk }
    }

    private var suggestion: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(SliveTheme.accent)
            switch transcription.status(for: Self.balanced) {
            case .downloading(let p):
                Text("Downloading large-v3 turbo")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textSecondary)
                ProgressView(value: p).frame(maxWidth: .infinity)
                Text("\(Int(p * 100))%")
                    .font(SliveTheme.mono(12))
                    .foregroundStyle(SliveTheme.accent)
                    .fixedSize()
            case .failed(let e):
                Text(e)
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.warnText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                downloadButton("Retry")
            default:
                Text("Whisper – large-v3 turbo is far more accurate · 600 MB")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textSecondary)
                Spacer(minLength: 0)
                downloadButton("Download")
                Button("Not now") { dismissed = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(10)
        .innerWell()
    }

    private func downloadButton(_ title: String) -> some View {
        Button(title) {
            let binding = $model
            Task {
                if await transcription.fetch(Self.balanced) { binding.wrappedValue = Self.balanced }
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(SliveTheme.accent)
        .fixedSize()
    }
}

/// The embeddable heart of the model picker: choice menu + detail line + live
/// download/prepare status row. Used by the dictation and continuous cards
/// AND the ground-truth judge — one component, identical download linkage
/// everywhere. The choices are `ModelCatalog`'s for `use`, one section per
/// engine, then the installed fine-tunes.
struct ModelPickerRows: View {
    @Binding var model: String
    @ObservedObject var transcription: TranscriptionModel
    let use: ModelUse

    var body: some View {
        let picked = ModelCatalog.resolve(model, for: use, custom: transcription.customModels)
        Group {
            HStack(spacing: 10) {
                Picker("", selection: $model) {
                    ForEach(Array(ModelCatalog.sections(for: use).enumerated()), id: \.offset) { i, section in
                        if i > 0 { Divider() }
                        ForEach(section) { d in
                            Text(d.label).tag(d.id)
                        }
                    }
                    if !transcription.customModels.isEmpty {
                        Divider()
                        ForEach(transcription.customModels) { custom in
                            Text(custom.displayName).tag(custom.id)
                        }
                    }
                    // Keep any custom/previously-saved model selectable.
                    if picked == nil {
                        Text("Custom").tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
                Text(picked?.detail ?? "Custom model · \(model)")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textMuted)
                Spacer(minLength: 0)
            }
            ModelStatusRow(transcription: transcription, model: model)
        }
        .onAppear { transcription.refreshCustomModels() }
    }
}
