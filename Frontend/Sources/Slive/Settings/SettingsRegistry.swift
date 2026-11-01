import SwiftUI

// The settings window's navigation, as data. Each page file declares its own
// `SettingsPageSpec` (id, title, icon, section, capability, width, status,
// view); the sidebar, the compact menu, the column caps and the title status
// all read the specs — nothing switches over pages.
//
// Adding a page: write `Settings/Pages/FooPage.swift` with the view, a
// `SettingsPageID.foo` and a `SettingsPageSpec.foo`, then add `.foo` to
// `SettingsRegistry.all` where it should sit in its section.

/// Sidebar groups, by what you're doing rather than by subsystem.
enum SettingsSection: String, CaseIterable, Identifiable {
    case app = "App"
    case modes = "Modes"
    case library = "Library"
    case lab = "Lab"
    var id: String { rawValue }
}

/// A page's stable identity. Navigation and attention use it; the title is
/// display copy and can change without touching either.
struct SettingsPageID: Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// How wide a page's column may grow at each tier.
enum SettingsPageWidth {
    /// Plain form pages.
    case form
    /// Row lists (History, Providers).
    case list
    /// Data may grow past the form cap — its table earns real width.
    case table
    /// General's two-column grid at the wide tier.
    case grid

    func cap(for layout: SliveLayout) -> CGFloat {
        let formCap = layout == .compact ? .infinity : SliveTheme.formWidth
        switch self {
        case .form: return formCap
        case .grid: return layout == .wide ? SliveTheme.generalGridWidth : formCap
        case .list: return layout == .compact ? .infinity : SliveTheme.historyWidth
        case .table:
            switch layout {
            case .compact: return .infinity
            case .regular: return SliveTheme.tableWidthRegular
            case .wide: return SliveTheme.tableWidthWide
            }
        }
    }
}

/// The one quiet status beside a page title.
struct SettingsPageStatus {
    var text: String?
    var color: Color = SliveTheme.textSecondary

    static let empty = SettingsPageStatus(text: nil)

    /// "Parakeet – Ultra · Ready" for a dictation model id.
    @MainActor
    static func model(_ model: String, _ transcription: TranscriptionModel) -> SettingsPageStatus {
        let name = ModelCatalog.resolve(model, custom: transcription.customModels)?.label ?? model
        let state: String
        switch transcription.status(for: model) {
        case .ready: state = "Ready"
        case .downloading: state = "Downloading"
        case .preparing: state = "Loading"
        case .failed: state = "Failed"
        case .notDownloaded: state = "Not downloaded"
        }
        return SettingsPageStatus(text: "\(name) · \(state)")
    }
}

/// What a page's view builder gets: the shared env and a way to move to
/// another page (e.g. Data → Providers for a missing key).
@MainActor
struct SettingsPageContext {
    let env: SettingsEnv
    let open: (SettingsPageID) -> Void
}

/// One page of the settings window.
struct SettingsPageSpec: Identifiable {
    let id: SettingsPageID
    /// Sidebar label and page title.
    let title: String
    /// SF Symbol for the sidebar row and compact menu.
    let icon: String
    let section: SettingsSection
    /// The capability the page needs; nil = every edition shows it.
    var requires: KeyPath<Capabilities, Bool>? = nil
    var width: SettingsPageWidth = .form
    var status: @MainActor (SettingsEnv) -> SettingsPageStatus = { _ in .empty }
    /// An orange dot in the sidebar (" •" in the compact menu).
    var needsAttention: @MainActor (SettingsEnv) -> Bool = { _ in false }
    let content: @MainActor (SettingsPageContext) -> AnyView

    func isAvailable(in capabilities: Capabilities) -> Bool {
        requires.map { capabilities[keyPath: $0] } ?? true
    }
}

enum SettingsRegistry {
    /// Every page, in sidebar order within its section.
    static let all: [SettingsPageSpec] = [
        .general,
        .permissions,
        .liveTyping,
        .assistant,
        .vocabulary,
        .history,
        .providers,
        .data,
        .training,
    ]

    /// The pages this edition shows.
    static func pages(for capabilities: Capabilities) -> [SettingsPageSpec] {
        all.filter { $0.isAvailable(in: capabilities) }
    }

    /// The pages of a section that this edition shows.
    static func pages(in section: SettingsSection, for capabilities: Capabilities) -> [SettingsPageSpec] {
        pages(for: capabilities).filter { $0.section == section }
    }

    /// The sections this edition has — Lite has no Lab (it needs the server).
    static func sections(for capabilities: Capabilities) -> [SettingsSection] {
        SettingsSection.allCases.filter { !pages(in: $0, for: capabilities).isEmpty }
    }

    /// The spec for an id, falling back to the first page this edition shows.
    static func spec(_ id: SettingsPageID, for capabilities: Capabilities) -> SettingsPageSpec {
        let visible = pages(for: capabilities)
        return visible.first { $0.id == id } ?? visible[0]
    }
}
