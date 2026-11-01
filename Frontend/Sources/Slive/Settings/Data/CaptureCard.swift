import SwiftUI

// MARK: - Capture (saving + size cap, one pipeline → one card)

struct CaptureCard: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: TrainingStore

    var body: some View {
        SettingsCard("CAPTURE") {
            ToggleRow(
                title: "Save dictations",
                isOn: $settings.captureEdits
            )
            CardDivider()
            HStack {
                Text("Max size")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Spacer()
                Text(String(format: "%.1f GB", settings.captureMaxGB))
                    .font(SliveTheme.mono(12))
                    .foregroundStyle(SliveTheme.accent)
            }
            Slider(value: $settings.captureMaxGB, in: 0.1...20, step: 0.1)
                .tint(SliveTheme.accent)

            // Usage bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SliveTheme.trackFill).frame(height: 6)
                    Capsule()
                        .fill(store.isOverLimit ? SliveTheme.warn : SliveTheme.accent)
                        .frame(width: max(4, geo.size.width * store.usageFraction), height: 6)
                }
                .frame(height: 6)
            }
            .frame(height: 6)

            HStack {
                Text("\(byteText(store.totalBytes)) of \(String(format: "%.1f GB", settings.captureMaxGB)) used")
                    .foregroundStyle(SliveTheme.textMuted)
                Spacer()
                if store.isOverLimit {
                    Label("Full · paused", systemImage: "pause.circle.fill")
                        .foregroundStyle(SliveTheme.warn)
                } else if settings.captureEdits {
                    Label("Capturing", systemImage: "record.circle")
                        .foregroundStyle(SliveTheme.ok)
                } else {
                    Text("Off").foregroundStyle(SliveTheme.textFaint)
                }
            }
            .font(SliveTheme.font(11, .semibold))
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
