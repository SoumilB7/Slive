import AppKit
import SwiftUI

/// The "Continuous" top-level section: live streaming dictation with its own
/// shortcut, transcription model, and typing-speed control — fully separate from
/// plain Dictation and the Assistant. Hold the shortcut and words type straight
/// into the focused field as you speak.
struct ContinuousSettingsView: View {
    @ObservedObject var settings: Settings
    var accent: Color
    @ObservedObject private var transcription = TranscriptionModel.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                stepsStrip
                shortcutCard
                modelCard
                typingSpeedCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .onAppear { transcription.select(settings.continuousModel) }
        .onChange(of: settings.continuousModel) { _, m in transcription.select(m) }
    }

    // MARK: - How it works

    private var stepsStrip: some View {
        HStack(spacing: 10) {
            step(icon: "hand.point.up.left.fill", title: "Hold", detail: streamLabel)
            arrow
            step(icon: "waveform", title: "Speak", detail: "Live")
            arrow
            step(icon: "text.cursor", title: "Types live", detail: "Into the field")
        }
    }

    private var streamLabel: String { settings.streamHotkey?.label ?? "Not set" }

    // MARK: - Shortcut

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CONTINUOUS DICTATION SHORTCUT")
            HotkeyRecorderView(
                accent: accent,
                target: .stream,
                title: "Continuous shortcut",
                subtitle: "Hold to transcribe as you speak — words type straight into the focused field, live."
            )
            if settings.streamHotkey == nil {
                Text("Continuous dictation is off until you record a shortcut.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: - Model

    /// On-device (Neural Engine) transcription model — accuracy vs. speed.
    private struct ModelChoice: Identifiable {
        let label: String
        let model: String
        let detail: String
        var id: String { model }
    }
    private let modelChoices: [ModelChoice] = [
        .init(label: "Tiny", model: "tiny.en", detail: "Fastest, basic accuracy · ~75 MB"),
        .init(label: "Fast", model: "base.en", detail: "Quick, good accuracy · ~150 MB"),
        .init(label: "Balanced", model: "large-v3-v20240930_626MB", detail: "Recommended — accurate & fast · ~600 MB"),
        .init(label: "Accurate", model: "large-v3", detail: "Highest accuracy, a touch slower · ~1.5 GB"),
    ]

    private var selectedModelDetail: String {
        modelChoices.first { $0.model == settings.continuousModel }?.detail
            ?? "Custom model · \(settings.continuousModel)"
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("MODEL")
            HStack(spacing: 10) {
                Picker("", selection: $settings.continuousModel) {
                    ForEach(modelChoices) { c in
                        Text(c.label).tag(c.model)
                    }
                    // Keep any custom/previously-saved model selectable.
                    if !modelChoices.contains(where: { $0.model == settings.continuousModel }) {
                        Text("Custom").tag(settings.continuousModel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accent)
                .fixedSize()
                Text(selectedModelDetail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }

            modelStatusRow

            Text("Streaming works best with Tiny or Fast — they keep up as you speak. Choosing the same model as Dictation keeps just one copy in memory.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    /// Status + Download control for the selected continuous model.
    @ViewBuilder private var modelStatusRow: some View {
        HStack(spacing: 10) {
            switch transcription.status(for: settings.continuousModel) {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready").foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button("Re-download") { Task { await transcription.redownload(settings.continuousModel) } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            case .notDownloaded:
                Image(systemName: "arrow.down.circle").foregroundStyle(accent)
                Text("Not downloaded").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Download") {
                    Task { await transcription.download(settings.continuousModel) }
                }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 120)
                Text("Downloading \(Int(p * 100))%").foregroundStyle(.white.opacity(0.7))
            case .preparing(let stage):
                ProgressView().controlSize(.small)
                Text("Preparing… (\(stage))").foregroundStyle(.white.opacity(0.7))
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                Spacer()
                Button("Re-download") { Task { await transcription.redownload(settings.continuousModel) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }

    // MARK: - Typing speed

    private var typingSpeedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TYPING SPEED")
            HStack {
                Text("Speed")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(typingSpeedLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            Slider(value: $settings.continuousTypeCPS, in: 12...120, step: 1)
                .tint(accent)
            Text("How fast dictated words appear as you speak. Instant types each phrase at once; lower is a smoother typewriter reveal.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var typingSpeedLabel: String {
        settings.continuousTypeCPS >= 120
            ? "Instant"
            : "\(Int(settings.continuousTypeCPS)) chars/sec"
    }

    // MARK: - Shared bits

    private func step(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(height: 24)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(card)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.25))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .tracking(1.2)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
            )
    }
}
