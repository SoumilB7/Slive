import AppKit
import SwiftUI

// MARK: - Navigation model

/// Top-level groups of the settings window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case assistant = "Assistant"
    case models = "Models"
    case training = "Training"
    var id: String { rawValue }
}

/// Every page the window can show — the single source of truth for navigation
/// (replaces the old Section/Tab/ATab trio). Dictation has five pages;
/// Assistant and Training are each one scrolling page.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case continuous = "Continuous"
    case permissions = "Permissions"
    case vocabulary = "Vocabulary"
    case history = "History"
    case assistant = "Assistant"
    case models = "Models"
    case training = "Training"
    var id: String { rawValue }

    var section: SettingsSection {
        switch self {
        case .general, .continuous, .permissions, .vocabulary, .history: return .dictation
        case .assistant: return .assistant
        case .models: return .models
        case .training: return .training
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .continuous: return "text.cursor"
        case .permissions: return "lock.shield.fill"
        case .vocabulary: return "character.book.closed.fill"
        case .history: return "clock.fill"
        case .assistant: return "sparkles"
        case .models: return "cpu.fill"
        case .training: return "tray.full.fill"
        }
    }

    static func first(in section: SettingsSection) -> SettingsPage {
        switch section {
        case .dictation: return .general
        case .assistant: return .assistant
        case .models: return .models
        case .training: return .training
        }
    }

    static func pages(in section: SettingsSection) -> [SettingsPage] {
        allCases.filter { $0.section == section }
    }
}

// MARK: - Sidebar

/// The regular/wide-tier navigation: brand lockup with a live model-status dot,
/// grouped page list, footer pinned to the bottom. Custom-drawn (not
/// NavigationSplitView) so it stays on the charcoal gradient.
struct SettingsSidebar: View {
    @Binding var page: SettingsPage

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

            ForEach(SettingsSection.allCases) { section in
                Text(section.rawValue.uppercased())
                    .font(SliveTheme.font(10, .bold))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .tracking(1.1)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                VStack(spacing: 2) {
                    ForEach(SettingsPage.pages(in: section)) { p in
                        SidebarRow(page: p, selected: page == p) { page = p }
                    }
                }
            }

            Spacer(minLength: 12)
            Text("Slive lives in your menu bar · v0.1")
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
