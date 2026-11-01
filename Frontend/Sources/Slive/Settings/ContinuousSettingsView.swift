import AppKit
import SwiftUI

/// The "Continuous" page under Dictation: live streaming dictation with its own
/// shortcut, transcription model, and typing-speed control. Renders just its
/// stack of cards — the host supplies the scroll container, padding, and width.
struct ContinuousSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var transcription = TranscriptionModel.shared

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            shortcutCard
            ModelPickerCard(
                title: "MODEL",
                model: $settings.continuousModel,
                help: "Parakeet keeps up best. Same as Dictation = less memory",
                includeParakeet: true
            )
            typingSpeedCard
        }
        .onAppear { transcription.select(settings.continuousModel) }
        .onChange(of: settings.continuousModel) { _, m in transcription.select(m) }
    }

    // MARK: - Shortcut

    private var shortcutCard: some View {
        SettingsCard("KEYS") {
            HStack(alignment: .center, spacing: 12) {
                HotkeyRecorderView(target: .stream, title: "Hold to type")
                    .opacity(settings.streamHoldOn ? 1 : 0.45)
                Toggle("", isOn: $settings.streamHoldOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
            }
            CardDivider()
            HStack(alignment: .center, spacing: 12) {
                HotkeyRecorderView(target: .streamToggle, title: "Tap to toggle")
                    .opacity(settings.streamToggleOn ? 1 : 0.45)
                Toggle("", isOn: $settings.streamToggleOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
            }
            if settings.streamHotkey == nil && settings.streamToggleHotkey == nil {
                Label("No shortcut set.", systemImage: "exclamationmark.triangle.fill")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
    }

    // MARK: - Typing speed

    /// Single-control card: the card title carries the row's meaning, the value
    /// readout sits in the title row.
    private var typingSpeedCard: some View {
        SettingsCard("TYPING SPEED", trailing: {
            Text(typingSpeedLabel)
                .font(SliveTheme.mono(12))
                .foregroundStyle(SliveTheme.accent)
        }) {
            Slider(value: $settings.continuousTypeCPS, in: 12...120, step: 1)
                .tint(SliveTheme.accent)
        }
    }

    private var typingSpeedLabel: String {
        settings.continuousTypeCPS >= 120
            ? "Instant"
            : "\(Int(settings.continuousTypeCPS)) chars/sec"
    }
}
