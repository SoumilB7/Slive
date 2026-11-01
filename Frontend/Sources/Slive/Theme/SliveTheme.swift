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

    // MARK: Text ramp
    /// Text tiers between the primary/secondary/tertiary anchors. Each value is
    /// what the views drew before the tiers were named.
    static let textStrong    = Color.white.opacity(0.95)  // selected sidebar label
    static let textBright    = Color.white.opacity(0.9)   // field text, hover-reveal icons
    static let textHigh      = Color.white.opacity(0.85)
    static let textBody      = Color.white.opacity(0.8)
    static let textSoft      = Color.white.opacity(0.7)
    static let textMuted     = Color.white.opacity(0.55)  // secondary glyphs and counts
    static let textDim       = Color.white.opacity(0.45)
    static let textFaint     = Color.white.opacity(0.4)   // placeholders, "Off", dashes
    static let textGhost     = Color.white.opacity(0.25)  // idle dot, empty-state glyph
    static let textOff       = Color.white.opacity(0.2)   // control disabled while running
    static let textBusy      = Color.white.opacity(0.15)  // control disabled while busy

    // MARK: Surfaces & lines
    /// Translucent white fills/strokes for insets, chips, tracks and hairlines.
    static let sidebarFill     = Color.white.opacity(0.03)
    static let insetFill       = Color.white.opacity(0.04)
    static let chipFill        = Color.white.opacity(0.07)
    static let trackFill       = Color.white.opacity(0.1)   // progress track
    static let trackFillSlim   = Color.white.opacity(0.08)  // thin progress track
    static let hairline        = Color.white.opacity(0.06)
    static let hairlineFaint   = Color.white.opacity(0.05)
    static let hairlineStrong  = Color.white.opacity(0.1)
    static let gridLine        = Color.white.opacity(0.12)  // chart baselines
    static let gridLineSoft    = Color.white.opacity(0.1)
    static let frameStroke     = Color.white.opacity(0.14)  // pill-position mock screen
    static let pillRing        = Color.white.opacity(0.2)
    static let pendingStroke   = Color.white.opacity(0.15)  // not-yet-reached stage ring

    // MARK: Accent tints
    static let accentText      = accent.opacity(0.85)  // accent-coloured captions/icons
    static let accentMuted     = accent.opacity(0.75)
    static let accentSoft      = accent.opacity(0.35)  // empty-state glyph, connected stroke
    static let accentRing      = accent.opacity(0.45)
    static let accentFocus     = accent.opacity(0.5)   // focused field stroke
    static let accentSelection = accent.opacity(0.18)  // selected sidebar row
    static let accentConnected = accent.opacity(0.16)  // connected card fill

    // MARK: Status
    /// warn = attention/needs-action orange; ok = granted/ready green;
    /// caution = battery-tier yellow.
    static let warn       = Color.orange
    static let warnText   = Color.orange.opacity(0.9)
    static let warnStrong = Color.orange.opacity(0.95)
    static let warnFill   = Color.orange.opacity(0.08)
    static let warnStroke = Color.orange.opacity(0.35)
    static let ok         = Color.green
    static let caution    = Color.yellow.opacity(0.85)

    /// Window backdrop behind the gradient.
    static let windowBackdrop = NSColor(white: 0.10, alpha: 1)

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

    /// System (non-rounded) face, for glyphs and compact tags.
    static func plain(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static let monoBody  = mono(12, .regular)
    static let monoSmall = mono(11, .regular)
    /// Tiny capsule badges (9pt) and tags (10pt), then labels and body text.
    static let badgeFont     = plain(9, .bold)
    static let chipFont      = plain(9, .semibold)
    static let tagFont       = plain(10, .semibold)
    static let tagBoldFont   = plain(10, .bold)
    static let labelFont     = plain(11, .semibold)
    static let labelBoldFont = plain(11, .bold)
    static let smallFont     = plain(11)
    static let controlFont   = plain(12, .semibold)
    static let bodyFont      = plain(12)
    /// Icon glyph sizes.
    static let iconFont   = plain(13, .semibold)
    static let iconMedium = plain(14)
    static let iconLarge  = plain(15)
    static let iconXL     = plain(20)
    static let iconHero   = plain(28, .medium)

    // MARK: Metrics
    static let cardRadius: CGFloat = 14
    /// Corner radii by role: field = text field/inset editor; row = list row,
    /// chip and sidebar item; mini = pill-position mock screen; tick = pill glyph.
    static let fieldRadius: CGFloat = 10
    static let rowRadius: CGFloat = 8
    static let miniRadius: CGFloat = 7
    static let tickRadius: CGFloat = 0.6
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
