import AppKit
import SwiftUI

/// Slive's home / settings window root. Owns navigation and the single scroll
/// container for every page, and adapts to the window width:
/// - compact (< 700pt): stacked segmented chrome, cards fill the width
/// - regular (≥ 700pt): themed sidebar + centered width-capped columns
/// - wide (≥ 1100pt): sidebar + wide treatments (General grid, wide Data table)
/// Pages, their order, caps and statuses come from `SettingsRegistry`.
struct SettingsView: View {
    let env: SettingsEnv
    // Observed so the title status and attention dots stay live.
    @ObservedObject private var settings: Settings
    @ObservedObject private var permissions: PermissionsModel
    @ObservedObject private var history: HistoryStore
    @ObservedObject private var transcription: TranscriptionModel
    @ObservedObject private var providers: ProviderStore
    @ObservedObject private var trainingStore: TrainingStore

    @StateObject private var scrollKeeper = SettingsScrollKeeper()
    @State private var page: SettingsPageID = .general
    @State private var width: CGFloat = SettingsWindowState.initialWidth()

    init(env: SettingsEnv) {
        self.env = env
        _settings = ObservedObject(wrappedValue: env.settings)
        _permissions = ObservedObject(wrappedValue: env.permissions)
        _history = ObservedObject(wrappedValue: env.history)
        _transcription = ObservedObject(wrappedValue: env.transcription)
        _providers = ObservedObject(wrappedValue: env.providers)
        _trainingStore = ObservedObject(wrappedValue: env.trainingStore)
    }

    private var layout: SliveLayout { SliveLayout.tier(for: width) }
    private var groups: [SettingsSidebarGroup] { SettingsSidebarGroup.groups(for: env.capabilities) }
    private var spec: SettingsPageSpec { SettingsRegistry.spec(page, for: env.capabilities) }

    private var attention: Set<SettingsPageID> {
        Set(SettingsRegistry.pages(for: env.capabilities).filter { $0.needsAttention(env) }.map(\.id))
    }

    var body: some View {
        Group {
            if layout == .compact {
                compactBody
            } else {
                sidebarBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SliveTheme.background.ignoresSafeArea())
        .environment(\.sliveLayout, layout)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    // MARK: - Compact chrome (< 700pt — today's stacked navigation)

    private var compactBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("Slive")
                    .font(SliveTheme.font(15, .semibold))
                    .foregroundStyle(SliveTheme.textPrimary)
                WhisperStatusDot(settings: settings, transcription: transcription)
                Spacer()
            }
            .padding(.horizontal, SliveTheme.gutter)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // One page picker, grouped like the sidebar.
            HStack {
                Menu {
                    let flagged = attention
                    ForEach(groups) { group in
                        Section(group.section.rawValue) {
                            ForEach(group.pages) { p in
                                Button {
                                    page = p.id
                                } label: {
                                    Label(p.title + (flagged.contains(p.id) ? " •" : ""),
                                          systemImage: p.icon)
                                }
                            }
                        }
                    }
                } label: {
                    Label(spec.title, systemImage: spec.icon)
                        .font(SliveTheme.rowFont)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tint(SliveTheme.accent)
                Spacer()
            }
            .padding(.horizontal, SliveTheme.gutter)
            .padding(.bottom, 4)

            scrollContainer

            Text(Bundle.main.versionLabel)
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.textTertiary)
                .padding(.top, 2)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Sidebar chrome (≥ 700pt)

    private var sidebarBody: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: $page, sections: groups, attention: attention,
                            settings: settings, transcription: transcription)
            scrollContainer
        }
    }

    /// THE scroll container — every page scrolls here, never internally.
    /// Pages that need to jump to an anchor (`.id(...)` on a row) get a
    /// scroll-to closure through `\.sliveScrollTo` instead of a proxy.
    private var scrollContainer: some View {
        let spec = spec
        let status = spec.status(env)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageTitle(title: spec.title, status: status.text,
                              statusColor: status.color)
                    spec.content(SettingsPageContext(env: env, open: { page = $0 }))
                        .id(spec.id)
                }
                .frame(maxWidth: spec.width.cap(for: layout))
                .padding(.top, layout == .compact ? 20 : 44)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, SliveTheme.gutter)
                .padding(.bottom, 14)
                .background(SettingsScrollResolver { scrollKeeper.scrollView = $0 })
            }
            .environment(\.sliveScrollTo) { id in
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .environment(\.slivePreserveScroll) { change in
                scrollKeeper.applyPreservingBottomDistance(change)
            }
        }
    }
}
