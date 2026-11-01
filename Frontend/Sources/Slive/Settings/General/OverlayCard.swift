import SwiftUI

/// What you see: where the pill sits (the preview is the control), how
/// solid it is, and whether results type in or show in the overlay.
struct OverlayCard: View {
    @ObservedObject var settings: Settings

    var body: some View {
        SettingsCard("OVERLAY") {
            HStack(alignment: .center, spacing: 20) {
                PillPositionPicker(settings: settings)
                VStack(alignment: .leading, spacing: 12) {
                    ToggleRow(title: "Type at cursor", isOn: $settings.autoInsert)
                        .help("Off: shows text in the overlay")
                    CardDivider()
                    SliderRow(
                        title: "Opacity",
                        value: $settings.overlayOpacity,
                        range: 0.35...1.0, step: 0.01,
                        valueText: "\(Int(settings.overlayOpacity * 100))%"
                    )
                }
            }
        }
    }
}
