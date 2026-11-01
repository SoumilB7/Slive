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
                RoundedRectangle(cornerRadius: SliveTheme.fieldRadius, style: .continuous)
                    .fill(SliveTheme.wellFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: SliveTheme.fieldRadius, style: .continuous)
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
        .foregroundStyle(SliveTheme.textFaint)
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
            StatusDot(color: SliveTheme.ok, size: 7).help("\(settings.whisperModel) ready")
        case .downloading, .preparing:
            StatusDot(color: SliveTheme.accent, pulses: true, size: 7)
                .help("\(settings.whisperModel) loading")
        case .failed:
            StatusDot(color: SliveTheme.warn, size: 7).help("Model failed to load")
        case .notDownloaded:
            StatusDot(color: SliveTheme.textGhost, size: 7)
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
                .font(SliveTheme.chipFont)
            Text(hasKey ? "Key" : "No key")
                .font(SliveTheme.font(10, .semibold))
        }
        .foregroundStyle(hasKey ? SliveTheme.accent : SliveTheme.warnText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(SliveTheme.wellFill)
                .overlay(Capsule().strokeBorder(SliveTheme.cardStroke, lineWidth: 0.8))
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
                .font(SliveTheme.chipFont)
            Text("On-device")
                .font(SliveTheme.font(10, .semibold))
        }
        .foregroundStyle(SliveTheme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(SliveTheme.wellFill)
                .overlay(Capsule().strokeBorder(SliveTheme.cardStroke, lineWidth: 0.8))
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
                .font(SliveTheme.iconHero)
                .foregroundStyle(SliveTheme.accentSoft)
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

/// Live download/prepare status + action for one model. minHeight keeps state
/// changes from reflowing the card.
struct ModelStatusRow: View {
    @ObservedObject private var transcription = TranscriptionModel.shared
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
    /// Tooltip on the picker.
    var help: String = ""
    /// Which catalog models it offers.
    let use: ModelUse
    /// Offer the large-v3 turbo download while on tiny/base (dictation card).
    var suggestBalanced = false

    var body: some View {
        SettingsCard(title) {
            ModelPickerRows(model: $model, use: use)
                .help(help)
            if suggestBalanced { BalancedSuggestion(model: $model) }
        }
    }
}

/// A fresh install dictates on the bundled tiny.en, which is far less
/// accurate. Point straight at large-v3 turbo ("Balanced") — not the
/// in-between sizes. The pick switches only once the download finished — a
/// failed or partial one never leaves dictation pointed at a model that
/// can't load; tiny keeps serving until turbo is ready.
struct BalancedSuggestion: View {
    @ObservedObject private var transcription = TranscriptionModel.shared
    @Binding var model: String
    @AppStorage("balancedSuggestionDismissed") private var dismissed = false
    static let balanced = ModelCatalog.balanced

    var body: some View {
        if ["tiny.en", "base.en"].contains(model), !dismissed, !transcription.isDownloaded(Self.balanced) {
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
    @ObservedObject private var transcription = TranscriptionModel.shared
    @Binding var model: String
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
            ModelStatusRow(model: model)
        }
        .onAppear { transcription.refreshCustomModels() }
    }
}
