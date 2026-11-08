import SwiftUI

/// Push-to-talk keys: hold and toggle, each with its own on/off switch.
struct KeysCard: View {
    @ObservedObject var settings: Settings

    var body: some View {
        SettingsCard("KEYS") {
            // Hold: press-and-speak. Its switch can turn the hold bind off
            // entirely (toggle-only users).
            HStack(alignment: .center, spacing: 12) {
                HotkeyRecorderView(settings: settings, target: .dictation, title: "Hold to talk")
                    .opacity(settings.dictateHoldOn ? 1 : 0.45)
                Toggle("", isOn: $settings.dictateHoldOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
            }
            CardDivider()
            // Toggle: tap to start, tap again to stop.
            HStack(alignment: .center, spacing: 12) {
                HotkeyRecorderView(settings: settings, target: .dictationToggle, title: "Tap to toggle")
                    .opacity(settings.dictateToggleOn ? 1 : 0.45)
                Toggle("", isOn: $settings.dictateToggleOn)
                    .labelsHidden().toggleStyle(.switch).tint(SliveTheme.accent)
            }
        }
    }
}
