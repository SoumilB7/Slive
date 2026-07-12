import AppKit
import SwiftUI

/// The design-token system for Slive's settings window. Every settings view
/// draws its colors, fonts, metrics, and width caps from here — nothing
/// hand-rolls an opacity or a corner radius at a call site.
enum SliveTheme {
    // MARK: Color
    static let accent        = Color(hue: 0.50, saturation: 0.68, brightness: 0.86)
    static let bgTop         = Color(hue: 0.53, saturation: 0.08, brightness: 0.15)
    static let bgBottom      = Color(hue: 0.53, saturation: 0.10, brightness: 0.09)
    static let textPrimary   = Color.white.opacity(0.92)
    static let textMid       = Color.white.opacity(0.75)
    static let textSecondary = Color.white.opacity(0.5)
    static let textTertiary  = Color.white.opacity(0.35)
    static let cardFill      = Color.white.opacity(0.05)
    static let cardStroke    = Color.white.opacity(0.08)
    static let wellFill      = Color.white.opacity(0.06)
    static let wellStroke    = Color.white.opacity(0.10)
    static let divider       = Color.white.opacity(0.08)

    // MARK: Type (SF Rounded everywhere)
    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Control-row label: 13pt semibold.
    static let rowFont = font(13, .semibold)
    /// Explanatory caption: 11pt medium.
    static let captionFont = font(11, .medium)
    /// UPPERCASE tracked card title: 11pt bold (+ .tracking(1.2) at the site).
    static let sectionFont = font(11, .bold)

    // MARK: Metrics
    static let cardRadius: CGFloat = 14
    static let cardPad: CGFloat = 16
    static let cardGap: CGFloat = 22
    static let gutter: CGFloat = 24
    static let gridGap: CGFloat = 20

    // MARK: Width caps & breakpoints
    static let formWidth: CGFloat = 580
    static let historyWidth: CGFloat = 680
    static let tableWidthRegular: CGFloat = 760
    static let tableWidthWide: CGFloat = 980
    static let generalGridWidth: CGFloat = 880
    static let sidebarWidth: CGFloat = 220
    static let sidebarBreakpoint: CGFloat = 700
    static let wideBreakpoint: CGFloat = 1100

    // MARK: Window (single source of truth — SettingsWindow reads these)
    static let windowDefault = NSSize(width: 860, height: 780)
    static let windowMin     = NSSize(width: 460, height: 520)

    /// The shared window background gradient.
    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Width tier of the settings window. Derived once from the root window width;
/// sub-views read it from the environment and never see raw widths.
enum SliveLayout {
    case compact   // < 700: stacked segmented chrome, full-width cards
    case regular   // 700–1099: sidebar + centered capped columns
    case wide      // ≥ 1100: sidebar + wide treatments (grids, wide table)

    static func tier(for width: CGFloat) -> SliveLayout {
        if width >= SliveTheme.wideBreakpoint { return .wide }
        if width >= SliveTheme.sidebarBreakpoint { return .regular }
        return .compact
    }
}

private struct SliveLayoutKey: EnvironmentKey {
    static let defaultValue: SliveLayout = .regular
}

extension EnvironmentValues {
    var sliveLayout: SliveLayout {
        get { self[SliveLayoutKey.self] }
        set { self[SliveLayoutKey.self] = newValue }
    }
}
