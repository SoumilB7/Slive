import AppKit
import SwiftUI

extension SettingsPageID {
    static let liveTyping = SettingsPageID("liveTyping")
}

extension SettingsPageSpec {
    static let liveTyping = SettingsPageSpec(
        id: .liveTyping, title: "Live typing", icon: "pencil.line", section: .modes,
        status: { env in .model(env.settings.continuousModel, env.transcription) }
    ) { ctx in
        AnyView(ContinuousSettingsView(settings: ctx.env.settings, transcription: ctx.env.transcription))
    }
}

/// The "Continuous" page under Dictation: live streaming dictation with its own
/// shortcut, transcription model, and typing-speed control. Renders just its
/// stack of cards — the host supplies the scroll container, padding, and width.
struct ContinuousSettingsView: View {
    @ObservedObject var settings: Settings
    let transcription: TranscriptionModel

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            shortcutCard
            ModelPickerCard(
                title: "MODEL",
                model: $settings.continuousModel,
                transcription: transcription,
                help: "Parakeet keeps up best. Same as Dictation = less memory",
                use: .continuous
            )
            typingSpeedCard
        }
        .onAppear { showStatus(settings.continuousModel) }
        .onChange(of: settings.continuousModel) { _, m in showStatus(m) }
    }

    /// Load the model only while live typing is on (AppDelegate keeps it
    /// resident then); otherwise just show its status — opening this page
    /// used to load a second model into RAM for a feature that's off.
    private func showStatus(_ model: String) {
        let on = (settings.streamHoldOn && settings.streamHotkey != nil)
            || (settings.streamToggleOn && settings.streamToggleHotkey != nil)
        if on { transcription.select(model) } else { transcription.refreshStatus(model) }
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
                    .foregroundStyle(SliveTheme.warnText)
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
