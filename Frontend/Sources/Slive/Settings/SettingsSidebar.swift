import AppKit
import SwiftUI

// MARK: - Navigation model

/// Sidebar groups, by what you're doing rather than by subsystem.
enum SettingsSection: String, CaseIterable, Identifiable {
    case app = "App"
    case modes = "Modes"
    case library = "Library"
    case lab = "Lab"
    var id: String { rawValue }
}

extension SettingsSection {
    /// The sections this edition has — Lite has no Lab (it needs the server).
    static var available: [SettingsSection] {
        allCases.filter { !SettingsPage.pages(in: $0).isEmpty }
    }
}

/// Every page the window can show — the single source of truth for navigation.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case permissions = "Permissions"
    case continuous = "Live typing"
    case assistant = "Ask"
    case vocabulary = "Vocabulary"
    case history = "History"
    case models = "Providers"
    case data = "Data"
    case training = "Training"
    var id: String { rawValue }

    var section: SettingsSection {
        switch self {
        case .general, .permissions: return .app
        case .continuous, .assistant: return .modes
        case .vocabulary, .history: return .library
        case .models, .data, .training: return .lab
        }
    }

    /// Pages that talk to the Python server — absent from the Lite edition.
    var needsServer: Bool {
        switch self {
        case .assistant, .models, .data, .training: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .continuous: return "pencil.line"
        case .permissions: return "lock.shield.fill"
        case .vocabulary: return "character.book.closed.fill"
        case .history: return "clock.fill"
        case .assistant: return "smallcircle.filled.circle"
        case .models: return "key.fill"
        case .data: return "tray.full.fill"
        case .training: return "waveform.path.ecg"
        }
    }

    /// The pages of a section that this edition shows.
    static func pages(in section: SettingsSection) -> [SettingsPage] {
        allCases.filter { $0.section == section && (Edition.hasServer || !$0.needsServer) }
    }
}

// MARK: - Sidebar

/// The regular/wide-tier navigation: brand lockup with a live model-status dot,
/// grouped page list, footer pinned to the bottom. Custom-drawn (not
/// NavigationSplitView) so it stays on the charcoal gradient.
struct SettingsSidebar: View {
    @Binding var page: SettingsPage
    /// Pages that need attention get an orange dot (missing permissions).
    var attention: Set<SettingsPage> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clears the floating traffic lights (.fullSizeContentView window).
            Spacer().frame(height: 28)

            HStack(spacing: 10) {
                BrandMark(size: 36)
                Text("Slive")
                    .font(SliveTheme.font(17, .bold))
                    .foregroundStyle(SliveTheme.textPrimary)
                WhisperStatusDot()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)

            ForEach(SettingsSection.available) { section in
                Text(section.rawValue.uppercased())
                    .font(SliveTheme.font(10, .bold))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .tracking(1.1)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                VStack(spacing: 2) {
                    ForEach(SettingsPage.pages(in: section)) { p in
                        SidebarRow(page: p, selected: page == p, attention: attention.contains(p)) { page = p }
                    }
                }
            }

            Spacer(minLength: 12)
            Text("v0.1")
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: SliveTheme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.white.opacity(0.03))
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
        }
    }

}

private struct SidebarRow: View {
    let page: SettingsPage
    let selected: Bool
    var attention = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SliveTheme.accent.opacity(0.85))
                    .frame(width: 16)
                Text(page.rawValue)
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(selected ? Color.white.opacity(0.95) : SliveTheme.textMid)
                Spacer(minLength: 0)
                if attention {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? SliveTheme.accent.opacity(0.18)
                          : hovering ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
