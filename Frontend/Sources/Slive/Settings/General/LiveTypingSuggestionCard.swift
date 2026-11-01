import SwiftUI

/// Live typing is a choice, so it starts off — but suggested once, with
/// the shortcuts Soumil uses. Gone when either shortcut is set or dismissed.
struct LiveTypingSuggestionCard: View {
    @ObservedObject var settings: Settings
    let transcription: TranscriptionModel

    @AppStorage("liveTypingSuggestionDismissed") private var liveTypingDismissed = false

    var body: some View {
        if settings.streamHotkey == nil, settings.streamToggleHotkey == nil, !liveTypingDismissed {
            SettingsCard("LIVE TYPING") {
                Text("Types while you speak. Hold ⌥ / or tap ⌥ . to start and stop.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Turn on") {
                        settings.streamHotkey = Settings.suggestedStreamHotkey
                        settings.streamToggleHotkey = Settings.suggestedStreamToggleHotkey
                        let model = settings.continuousModel
                        if !transcription.isDownloaded(model) {
                            Task { await transcription.download(model) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SliveTheme.accent)
                    .controlSize(.small)
                    Button("Not now") { liveTypingDismissed = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
