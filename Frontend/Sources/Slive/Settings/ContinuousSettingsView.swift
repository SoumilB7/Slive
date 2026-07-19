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
                footnote: "Tiny or Fast keep up best as the words fly by. Match your Dictation model and only one copy sits in memory."
            )
            typingSpeedCard
        }
        .onAppear { transcription.select(settings.continuousModel) }
        .onChange(of: settings.continuousModel) { _, m in transcription.select(m) }
    }

    // MARK: - Shortcut

    private var shortcutCard: some View {
        SettingsCard("CONTINUOUS SHORTCUT") {
            HotkeyRecorderView(
                target: .stream,
                title: "Continuous shortcut",
                subtitle: "Hold it and your words type themselves into the field, live, as you talk."
            )
            CardDivider()
            if settings.streamHotkey == nil {
                Label("Continuous dictation stays asleep until you record a shortcut.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.9))
            } else {
                StepsRibbon(steps: [
                    .init(icon: "hand.point.up.left.fill", text: "Hold",
                          key: settings.streamHotkey?.label),
                    .init(icon: "waveform", text: "Speak"),
                    .init(icon: "text.cursor", text: "Types live"),
                ])
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
            Text("How fast words land as you talk. Instant drops each phrase at once; lower is a smooth typewriter roll.")
                .sliveCaption()
        }
    }

    private var typingSpeedLabel: String {
        settings.continuousTypeCPS >= 120
            ? "Instant"
            : "\(Int(settings.continuousTypeCPS)) chars/sec"
    }
}
