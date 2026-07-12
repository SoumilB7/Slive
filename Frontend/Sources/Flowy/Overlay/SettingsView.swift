import SwiftUI

/// Flowy's home / settings screen. Doubles as the "what is this" surface:
/// a hero, a three-step explainer, the push-to-talk key picker, and live
/// permission status you can grant in place.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: PermissionsModel
    var audiosPath: String
    var onOpenAudios: () -> Void
    var onRelaunch: () -> Void

    private let accent = Color(hue: 0.76, saturation: 0.7, brightness: 1.0)

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                steps
                keyPicker
                permissionsSection
                generalSection
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 460, height: 640)
        .background(background)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(hue: 0.72, saturation: 0.10, brightness: 0.16),
                     Color(hue: 0.80, saturation: 0.14, brightness: 0.10)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            BrandMark(size: 76)
            Text("Flowy")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Hold a key. Speak. It's saved.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 6)
    }

    // MARK: - How it works

    private var steps: some View {
        HStack(spacing: 10) {
            step(icon: "hand.point.up.left.fill",
                 title: "Hold", detail: settings.hotkey.title)
            arrow
            step(icon: "waveform", title: "Speak", detail: "Live waveform")
            arrow
            step(icon: "checkmark.circle.fill", title: "Release", detail: "Saved as MP3")
        }
    }

    private func step(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(height: 24)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(card)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.25))
    }

    // MARK: - Key picker

    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("PUSH-TO-TALK KEY")
            Picker("", selection: $settings.hotkey) {
                ForEach(HotkeyChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(settings.hotkey.subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("PERMISSIONS")
            permissionRow(
                title: "Input Monitoring",
                detail: "Detect your push-to-talk key",
                granted: permissions.inputMonitoringGranted,
                action: { permissions.requestInputMonitoring() }
            )
            Divider().overlay(.white.opacity(0.08))
            permissionRow(
                title: "Microphone",
                detail: "Record your voice",
                granted: permissions.micGranted,
                action: { permissions.requestMic() }
            )
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(accent)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Just enabled Input Monitoring?")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("macOS only applies it after a relaunch.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button("Relaunch", action: onRelaunch)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
                .shadow(color: (granted ? Color.green : Color.orange).opacity(0.7), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("GENERAL")
            Toggle(isOn: $settings.launchAtLogin) {
                Text("Launch at login")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .toggleStyle(.switch)
            .tint(accent)
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recordings folder")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(audiosPath)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Open", action: onOpenAudios)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Flowy lives in your menu bar · v0.1")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 2)
    }

    // MARK: - Shared bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .tracking(1.2)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
            )
    }
}
