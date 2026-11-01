import SwiftUI

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
