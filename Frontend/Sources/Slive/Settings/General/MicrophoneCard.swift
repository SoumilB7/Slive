import SwiftUI

/// Meet-style mic menu: system default first (named, so you know what
/// "default" means today), then every connected input. Applies to hold
/// AND continuous dictation from the next recording.
struct MicrophoneCard: View {
    @ObservedObject var settings: Settings
    @ObservedObject var inputDevices: InputDevices

    /// The chosen mic, if it's connected right now.
    private var chosenMic: InputDevices.Device? {
        inputDevices.device(forUID: settings.inputDeviceUID)
    }

    var body: some View {
        SettingsCard("MICROPHONE") {
            HStack(spacing: 10) {
                Picker("", selection: $settings.inputDeviceUID) {
                    Text("System default" + (inputDevices.systemDefault.map { " · \($0.name)" } ?? ""))
                        .tag("")
                    if !inputDevices.devices.isEmpty { Divider() }
                    ForEach(inputDevices.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // A saved pick that isn't plugged in stays selectable so
                    // it takes effect again the moment it returns.
                    if !settings.inputDeviceUID.isEmpty && chosenMic == nil {
                        Text("\(settings.inputDeviceName.isEmpty ? "Chosen mic" : settings.inputDeviceName) (not connected)")
                            .tag(settings.inputDeviceUID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
                .help("Used for dictation and live typing")
                .onChange(of: settings.inputDeviceUID) { _, uid in
                    settings.inputDeviceName = inputDevices.device(forUID: uid)?.name ?? ""
                }
                micDetail
                Spacer(minLength: 0)
            }
            if settings.echoCancellation {
                // The canceller needs the speaker signal, so it follows the
                // system default route and the pick above is ignored.
                HStack(spacing: 8) {
                    Text("Echo cancellation uses the system mic.")
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.warn)
                    Button("Turn off") { settings.echoCancellation = false }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if activeMic?.transport == "Bluetooth" {
                // Opening a Bluetooth mic drops headphones to call quality.
                Text("Pick Built-in to keep music quality.")
                    .sliveCaption()
            }
            CardDivider()
            ToggleRow(title: "Echo cancellation", isOn: $settings.echoCancellation)
                .help("Removes speaker sound from the mic. May pop on start.")
        }
    }

    /// The mic recording will actually open (the pick, or the default).
    private var activeMic: InputDevices.Device? {
        chosenMic ?? (settings.inputDeviceUID.isEmpty ? inputDevices.systemDefault : nil)
    }

    @ViewBuilder private var micDetail: some View {
        if let mic = activeMic {
            Text(mic.detail)
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.textMuted)
        } else if !settings.inputDeviceUID.isEmpty {
            Text("Not connected · using \(inputDevices.systemDefault?.name ?? "system default")")
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.warn)
        }
    }
}
