import SwiftUI

extension SettingsPageID {
    static let permissions = SettingsPageID("permissions")
}

extension SettingsPageSpec {
    static let permissions = SettingsPageSpec(
        id: .permissions, title: "Permissions", icon: "lock.shield.fill", section: .app,
        status: { env in
            let p = env.permissions
            return SettingsPageStatus(text: "\(p.grantedCount) of \(PermissionsModel.required) granted",
                                      color: p.needsAttention ? SliveTheme.warn : SliveTheme.textSecondary)
        },
        needsAttention: { env in env.permissions.needsAttention }
    ) { ctx in
        AnyView(PermissionsPage(permissions: ctx.env.permissions, settings: ctx.env.settings,
                                onRelaunch: ctx.env.relaunch))
    }
}

/// Dictation · Permissions.
struct PermissionsPage: View {
    @ObservedObject var permissions: PermissionsModel
    /// Observed for `hotkeyActive` (a working event tap counts as granted).
    @ObservedObject var settings: Settings
    let onRelaunch: () -> Void

    var body: some View {
        SettingsCard("") {
            permissionRow(
                title: "Input Monitoring",
                detail: "Detects your shortcut",
                granted: permissions.inputMonitoringWorks,
                action: { permissions.requestInputMonitoring() }
            )
            CardDivider()
            permissionRow(
                title: "Microphone",
                detail: "Hears you",
                granted: permissions.micGranted,
                action: { permissions.requestMic() }
            )
            CardDivider()
            permissionRow(
                title: "Accessibility",
                detail: "Types into apps",
                granted: permissions.accessibilityGranted,
                action: { permissions.requestAccessibility() }
            )
            CardDivider()
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(SliveTheme.accent)
                    .font(SliveTheme.iconMedium)
                Text("Applies after relaunch.")
                    .sliveCaption()
                Spacer()
                Button("Relaunch", action: onRelaunch)
                    .buttonStyle(.bordered)
                    .tint(SliveTheme.accent)
                    .controlSize(.small)
            }
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            StatusDot(color: granted ? SliveTheme.ok : SliveTheme.warn, pulses: !granted, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Text(detail).sliveCaption()
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(SliveTheme.font(12, .semibold))
                    .foregroundStyle(SliveTheme.ok)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(SliveTheme.accent)
                    .controlSize(.small)
            }
        }
    }
}
