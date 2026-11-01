import SwiftUI

/// Hold delay, login item, problem reports, developer logs.
struct BehaviorCard: View {
    @ObservedObject var settings: Settings

    var body: some View {
        SettingsCard("BEHAVIOR") {
            SliderRow(
                title: "Hold delay",
                value: $settings.holdActivationDelay,
                range: 0...0.6, step: 0.05,
                valueText: String(format: "%.2fs", settings.holdActivationDelay)
            )
            .help("Wait before recording starts")
            CardDivider()
            ToggleRow(title: "Launch at login", isOn: $settings.launchAtLogin)
            CardDivider()
            ToggleRow(title: "Offer to report problems", isOn: $settings.reportProblems)
                .help("After a crash or freeze, offer a GitHub issue. Personal details are removed.")
            CardDivider()
            ToggleRow(title: "Developer logs", isOn: $settings.verboseLogging)
                .help("Console.app · filter Slive")
        }
    }
}
