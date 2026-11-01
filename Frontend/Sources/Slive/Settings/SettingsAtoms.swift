import AppKit
import SwiftUI

// The composable atoms the settings pages are built from. Card chrome, row
// anatomy, status presentation — defined once here, consumed everywhere, so no
// page hand-rolls fonts or opacities again.

// MARK: - Scroll-to environment

/// Jump the settings window's single scroll container to a `.id(...)` anchor.
/// Set by SettingsView (which owns THE ScrollView); pages call it to deep-link
/// into their own content (e.g. "jump to the first way-off row").
private struct SliveScrollToKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var sliveScrollTo: (String) -> Void {
        get { self[SliveScrollToKey.self] }
        set { self[SliveScrollToKey.self] = newValue }
    }
}

/// Runs a content mutation while keeping the root settings viewport at the
/// same distance from the bottom. Data pagination uses this so differently
/// sized pages don't leave the reader halfway through an unrelated row.
private struct SlivePreserveScrollKey: EnvironmentKey {
    static let defaultValue: (@escaping () -> Void) -> Void = { change in change() }
}

extension EnvironmentValues {
    var slivePreserveScroll: (@escaping () -> Void) -> Void {
        get { self[SlivePreserveScrollKey.self] }
        set { self[SlivePreserveScrollKey.self] = newValue }
    }
}

// MARK: - Card chrome

private struct SliveCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(SliveTheme.cardPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SliveTheme.cardRadius, style: .continuous)
                    .fill(SliveTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: SliveTheme.cardRadius, style: .continuous)
                            .strokeBorder(SliveTheme.cardStroke, lineWidth: 0.8)
                    )
            )
    }
}

private struct SliveCaptionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(SliveTheme.captionFont)
            .foregroundStyle(SliveTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The inner well: recessed rounded box for editors and previews inside a card.
private struct InnerWellModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SliveTheme.wellFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(SliveTheme.wellStroke, lineWidth: 0.8)
                    )
            )
    }
}

extension View {
    /// Standard card chrome: 16pt padding, full-width leading, 14pt continuous
    /// rounded rect (white 5% fill, 8% stroke).
    func sliveCard() -> some View { modifier(SliveCardModifier()) }
    /// Standard 11pt caption styling.
    func sliveCaption() -> some View { modifier(SliveCaptionModifier()) }
    /// Recessed well chrome for editors/previews inside a card.
    func innerWell() -> some View { modifier(InnerWellModifier()) }
}

/// UPPERCASE tracked card title.
func SliveSectionTitle(_ text: String) -> some View {
    Text(text)
        .font(SliveTheme.sectionFont)
        .foregroundStyle(.white.opacity(0.4))
        .tracking(1.2)
}

/// A card: title row (with optional trailing accessory) above its content.
struct SettingsCard<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A card that is a page's only card drops its title (the page
            // title says it); the row stays if it carries a trailing control.
            if !title.isEmpty || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !title.isEmpty { SliveSectionTitle(title) }
                    Spacer(minLength: 0)
                    trailing
                }
            }
            content
        }
        .sliveCard()
    }
}

/// The row at the top of every page: its name, and one quiet status.
struct PageTitle: View {
    let title: String
    var status: String?
    var statusColor: Color = SliveTheme.textSecondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(SliveTheme.font(17, .bold))
                .foregroundStyle(SliveTheme.textPrimary)
            Spacer(minLength: 0)
            if let status {
                Text(status)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
    }
}

/// Divider between rows of a multi-row card.
struct CardDivider: View {
    var body: some View { Divider().overlay(SliveTheme.divider) }
}

// MARK: - Control rows

/// Toggle row: title (+ optional caption) leading, accent switch trailing.
struct ToggleRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                if let caption {
                    Text(caption).sliveCaption()
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SliveTheme.accent)
        }
    }
}

/// Slider row: title + mono value header, accent slider, caption below.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Spacer()
                Text(valueText)
                    .font(SliveTheme.mono(12))
                    .foregroundStyle(SliveTheme.accent)
            }
            Slider(value: $value, in: range, step: step)
                .tint(SliveTheme.accent)
            if let caption {
                Text(caption).sliveCaption()
            }
        }
    }
}

// MARK: - Status atoms

/// A small glowing status dot; orange dots may pulse ("needs attention").
struct StatusDot: View {
    let color: Color
    var pulses = false
    var size: CGFloat = 8

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: 4)
            .opacity(dim ? 0.55 : 1)
            .onAppear { if pulses { startPulse() } }
            .onChange(of: pulses) { _, on in
                // Replacing the animation on `dim` cancels the repeatForever —
                // otherwise it keeps ticking invisibly after the dot goes solid.
                if on {
                    startPulse()
                } else {
                    withAnimation(.linear(duration: 0.01)) { dim = false }
                }
            }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            dim = true
        }
    }
}

/// 7pt dot beside the brand lockup reflecting the active dictation model:
/// green = ready, pulsing accent = downloading/preparing, orange = failed,
/// faint = not downloaded.
struct WhisperStatusDot: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var transcription = TranscriptionModel.shared

    var body: some View {
        switch transcription.status(for: settings.whisperModel) {
        case .ready:
            StatusDot(color: .green, size: 7).help("\(settings.whisperModel) ready")
        case .downloading, .preparing:
            StatusDot(color: SliveTheme.accent, pulses: true, size: 7)
                .help("\(settings.whisperModel) loading")
        case .failed:
            StatusDot(color: .orange, size: 7).help("Model failed to load")
        case .notDownloaded:
            StatusDot(color: .white.opacity(0.25), size: 7)
                .help("\(settings.whisperModel) not downloaded")
        }
    }
}

/// Capsule reporting whether a provider key is present in the Keychain.
struct KeyStatusPill: View {
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: hasKey ? "checkmark.circle.fill" : "key.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(hasKey ? "Key" : "No key")
                .font(SliveTheme.font(10, .semibold))
        }
        .foregroundStyle(hasKey ? SliveTheme.accent : .orange.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        )
    }
}

/// The Local provider's runtime knobs — quantization and the memory ceiling.
/// Shown in the Models page's Local row.
struct LocalInferenceControls: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToggleRow(
                title: "Quantized",
                caption: "8-bit weights — 30–50% less memory for near-identical answers. Flip it and the model reloads on your next ask.",
                isOn: $settings.localQuantized
            )
            SliderRow(
                title: "Memory limit",
                value: $settings.localMemLimitGB,
                range: 2...Settings.localMemMaxGB(ramGB: MachineProfile.ramGB),
                step: 1,
                valueText: "\(Int(settings.localMemLimitGB)) GB",
                caption: "Too big to fit under the limit? Slive turns it away with an error instead of freezing your Mac."
            )
        }
    }
}

/// KeyStatusPill's stand-in for the Local provider: there is no key to show —
/// the model runs on this Mac.
struct OnDevicePill: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 9, weight: .semibold))
            Text("On-device")
                .font(SliveTheme.font(10, .semibold))
        }
        .foregroundStyle(SliveTheme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(.white.opacity(0.06))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        )
    }
}

// MARK: - Empty state

/// Centered quiet empty-state block for lists with nothing in them yet.
struct EmptyState: View {
    let icon: String
    let title: String
    var caption: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(SliveTheme.accent.opacity(0.35))
            Text(title)
                .font(SliveTheme.rowFont)
                .foregroundStyle(SliveTheme.textPrimary)
            if let caption {
                Text(caption)
                    .sliveCaption()
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Transcription model picker (shared by General + Continuous)

/// The on-device Whisper model choices offered in the pickers.
struct WhisperModelChoice: Identifiable {
    let label: String
    let model: String
    let detail: String
    var id: String { model }

    static let all: [WhisperModelChoice] = [
        .init(label: "Whisper – tiny.en", model: "tiny.en", detail: "Fastest · 75 MB"),
        .init(label: "Whisper – base.en", model: "base.en", detail: "Fast · 150 MB"),
        .init(label: "Whisper – large-v3 turbo", model: "large-v3-v20240930_626MB", detail: "Recommended · 600 MB"),
        .init(label: "Whisper – large-v3", model: "large-v3", detail: "Most accurate · 1.5 GB"),
    ]

    /// The Parakeet engine (FluidAudio, Neural Engine). Offered only where a
    /// caller opts in — hold-to-talk dictation. Continuous (WhisperKit's
    /// live streaming) and the ground-truth judge stay Whisper-only.
    static let parakeet: [WhisperModelChoice] = [
        .init(label: ParakeetModel.ultra.displayName, model: ParakeetModel.ultra.rawValue,
              detail: "Fastest · weaker on names · 610 MB"),
        .init(label: ParakeetModel.v2.displayName, model: ParakeetModel.v2.rawValue,
              detail: "English · 450 MB"),
    ]
}

/// Live download/prepare status + action for one model. minHeight keeps state
/// changes from reflowing the card.
struct ModelStatusRow: View {
    @ObservedObject private var transcription = TranscriptionModel.shared
    let model: String

    var body: some View {
        HStack(spacing: 10) {
            switch transcription.status(for: model) {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready").foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button("Re-download") { Task { await transcription.redownload(model) } }
                    .buttonStyle(.plain)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            case .notDownloaded:
                Image(systemName: "arrow.down.circle").foregroundStyle(SliveTheme.accent)
                Text("Not downloaded").foregroundStyle(.white.opacity(0.7))
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
                Text("\(stage)…").foregroundStyle(.white.opacity(0.7))
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
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
    /// Tooltip on the picker.
    var help: String = ""
    var includeParakeet = false
    /// Offer the large-v3 turbo download while on tiny/base (dictation card).
    var suggestBalanced = false

    var body: some View {
        SettingsCard(title) {
            ModelPickerRows(model: $model, includeParakeet: includeParakeet)
                .help(help)
            if suggestBalanced { BalancedSuggestion(model: $model) }
        }
    }
}

/// A fresh install dictates on the bundled tiny.en, which is far less
/// accurate. Point straight at large-v3 turbo ("Balanced") — not the
/// in-between sizes. Tapping Download selects it; tiny keeps serving until
/// it's ready.
struct BalancedSuggestion: View {
    @ObservedObject private var transcription = TranscriptionModel.shared
    @Binding var model: String
    static let balanced = "large-v3-v20240930_626MB"

    var body: some View {
        if ["tiny.en", "base.en"].contains(model), !transcription.isDownloaded(Self.balanced) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(SliveTheme.accent)
                Text("Whisper – large-v3 turbo is far more accurate · 600 MB")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textSecondary)
                Spacer(minLength: 0)
                Button("Download") {
                    model = Self.balanced
                    Task { await transcription.download(Self.balanced) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(SliveTheme.accent)
                .fixedSize()
            }
            .padding(10)
            .innerWell()
        }
    }
}

/// The embeddable heart of the Whisper model picker: choice menu + detail line
/// + live download/prepare status row. Used by the dictation model card AND
/// anywhere else that selects an on-device Whisper model (ground truth) — one
/// component, identical download linkage everywhere.
struct ModelPickerRows: View {
    @ObservedObject private var transcription = TranscriptionModel.shared
    @Binding var model: String
    /// Offer the Parakeet ("Instant") models — hold-to-talk dictation only.
    var includeParakeet = false

    private var choices: [WhisperModelChoice] {
        WhisperModelChoice.all + (includeParakeet ? WhisperModelChoice.parakeet : [])
    }

    var body: some View {
        Group {
            HStack(spacing: 10) {
                Picker("", selection: $model) {
                    ForEach(WhisperModelChoice.all) { c in
                        Text(c.label).tag(c.model)
                    }
                    if includeParakeet {
                        Divider()
                        ForEach(WhisperModelChoice.parakeet) { c in
                            Text(c.label).tag(c.model)
                        }
                    }
                    if !transcription.customModels.isEmpty {
                        Divider()
                        ForEach(transcription.customModels) { custom in
                            Text(custom.displayName).tag(custom.id)
                        }
                    }
                    // Keep any custom/previously-saved model selectable.
                    if !choices.contains(where: { $0.model == model })
                        && !transcription.customModels.contains(where: { $0.id == model }) {
                        Text("Custom").tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
                Text(choices.first { $0.model == model }?.detail
                     ?? transcription.customModels.first { $0.id == model }
                        .map { "Fine-tuned \($0.baseModel) · \($0.id)" }
                     ?? "Custom model · \(model)")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
            ModelStatusRow(model: model)
        }
        .onAppear { transcription.refreshCustomModels() }
    }
}
