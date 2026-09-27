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
                footnote: "Parakeet re-reads everything you've said many times a second, so it keeps up best; on Whisper, tiny.en or base.en stay quickest. Match your Dictation model and only one copy sits in memory.",
                includeParakeet: true
            )
            typingSpeedCard
        }
        .onAppear { transcription.select(settings.continuousModel) }
        .onChange(of: settings.continuousModel) { _, m in transcription.select(m) }
    }

    // MARK: - Shortcut

    private var shortcutCard: some View {
        SettingsCard("CONTINUOUS KEYS") {
            HStack(alignment: .top, spacing: 12) {
                HotkeyRecorderView(
                    target: .stream,
                    title: "Hold to stream",
                    subtitle: "Hold it and your words type themselves into the field, live, as you talk.")
                    .opacity(settings.streamHoldOn ? 1 : 0.45)
                Toggle("", isOn: $settings.streamHoldOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
                    .help("Turn the hold bind on or off")
            }
            CardDivider()
            HStack(alignment: .top, spacing: 12) {
                HotkeyRecorderView(
                    target: .streamToggle,
                    title: "Tap to toggle",
                    subtitle: "Tap once to start live typing, tap again to finish.")
                    .opacity(settings.streamToggleOn ? 1 : 0.45)
                Toggle("", isOn: $settings.streamToggleOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
                    .help("Turn the toggle bind on or off")
            }
            CardDivider()
            if settings.streamHotkey == nil && settings.streamToggleHotkey == nil {
                Label("Continuous dictation stays asleep until you record a shortcut.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.9))
            } else {
                StepsRibbon(steps: [
                    .init(icon: "hand.point.up.left.fill", text: "Hold or tap",
                          key: (settings.streamHotkey ?? settings.streamToggleHotkey)?.label),
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
