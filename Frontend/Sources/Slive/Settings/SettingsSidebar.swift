import AppKit
import SwiftUI

// MARK: - Sidebar

/// The regular/wide-tier navigation: brand lockup with a live model-status dot,
/// grouped page list, footer pinned to the bottom. Custom-drawn (not
/// NavigationSplitView) so it stays on the charcoal gradient.
struct SettingsSidebar: View {
    @Binding var page: SettingsPageID
    /// The registry's pages for this edition, grouped by section.
    let sections: [SettingsSidebarGroup]
    /// Pages that need attention get an orange dot (missing permissions).
    var attention: Set<SettingsPageID> = []
    let settings: Settings
    let transcription: TranscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clears the floating traffic lights (.fullSizeContentView window).
            Spacer().frame(height: 28)

            HStack(spacing: 10) {
                BrandMark(size: 36)
                Text("Slive")
                    .font(SliveTheme.font(17, .bold))
                    .foregroundStyle(SliveTheme.textPrimary)
                WhisperStatusDot(settings: settings, transcription: transcription)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)

            ForEach(sections) { group in
                Text(group.section.rawValue.uppercased())
                    .font(SliveTheme.font(10, .bold))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .tracking(1.1)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                VStack(spacing: 2) {
                    ForEach(group.pages) { p in
                        SidebarRow(page: p, selected: page == p.id, attention: attention.contains(p.id)) {
                            page = p.id
                        }
                    }
                }
            }

            Spacer(minLength: 12)
            Text(Bundle.main.versionLabel)
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: SliveTheme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SliveTheme.sidebarFill)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SliveTheme.wellFill).frame(width: 1)
        }
    }

}

/// One sidebar (and compact-menu) section with the pages this edition shows.
struct SettingsSidebarGroup: Identifiable {
    let section: SettingsSection
    let pages: [SettingsPageSpec]
    var id: SettingsSection { section }

    static func groups(for capabilities: Capabilities) -> [SettingsSidebarGroup] {
        SettingsRegistry.sections(for: capabilities).map {
            SettingsSidebarGroup(section: $0, pages: SettingsRegistry.pages(in: $0, for: capabilities))
        }
    }
}

private struct SidebarRow: View {
    let page: SettingsPageSpec
    let selected: Bool
    var attention = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.icon)
                    .font(SliveTheme.controlFont)
                    .foregroundStyle(SliveTheme.accentText)
                    .frame(width: 16)
                Text(page.title)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(selected ? SliveTheme.textStrong : SliveTheme.textMid)
                Spacer(minLength: 0)
                if attention {
                    Circle().fill(SliveTheme.warn).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
                    .fill(selected ? SliveTheme.accentSelection
                          : hovering ? SliveTheme.wellFill : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
