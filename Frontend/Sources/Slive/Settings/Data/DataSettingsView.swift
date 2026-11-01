import AppKit
import SwiftUI

extension SettingsPageID {
    static let data = SettingsPageID("data")
}

extension SettingsPageSpec {
    static let data = SettingsPageSpec(
        id: .data, title: "Data", icon: "tray.full.fill", section: .lab,
        requires: \.training,
        width: .table,
        status: { env in
            let store = env.trainingStore
            guard store.count > 0 else { return .empty }
            let size = ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file)
            return SettingsPageStatus(text: "\(store.count) sample\(store.count == 1 ? "" : "s") · \(size)")
        }
    ) { ctx in
        AnyView(DataSettingsView(env: ctx.env, openModels: { ctx.open(.providers) }))
    }
}

/// The Data page: capture pipeline (CAPTURE), ground-truth transcription
/// (GROUND TRUTH), and the sample browser (DATA) — one scrolling flow, no
/// drill-in. This is the fuel side of fine-tuning; the Training page next
/// door burns it. Renders just its stack; the host supplies scroll and outer
/// width (which lets DATA grow past the form cap at wide sizes).
struct DataSettingsView: View {
    let env: SettingsEnv
    @ObservedObject private var store: TrainingStore
    @Environment(\.sliveLayout) private var layout
    @Environment(\.sliveScrollTo) private var scrollTo
    /// Navigates to the Models page (key entry lives there).
    let openModels: () -> Void

    @State private var samplePage = 0

    init(env: SettingsEnv, openModels: @escaping () -> Void) {
        self.env = env
        _store = ObservedObject(wrappedValue: env.trainingStore)
        self.openModels = openModels
    }

    private var pageCount: Int { DataTableCard.pageCount(for: store.count) }

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            // The one place two columns genuinely pay: the two form cards
            // side by side, the table full-width below. One AnyLayout (not an
            // if/else) so crossing the breakpoint keeps the ground-truth
            // card's editor state.
            formCardsLayout {
                captureCard.frame(maxWidth: formCardCap)
                groundTruthCard.frame(maxWidth: formCardCap)
            }
            DataTableCard(settings: env.settings, store: store, run: env.labelRun,
                          player: env.player, samplePage: $samplePage)
        }
        .onAppear {
            store.loadSamplesIfNeeded()   // lazy index parse
            store.recheckAudio()          // clips deleted in Finder since last visit
            env.labelRun.refreshScope()   // price the one-click run right away
        }
        .onChange(of: store.count) { _, _ in
            samplePage = min(samplePage, pageCount - 1)
        }
        .onDisappear { env.player.stop() }
    }

    private var formCardsLayout: AnyLayout {
        layout == .wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: SliveTheme.gridGap))
            : AnyLayout(VStackLayout(spacing: SliveTheme.cardGap))
    }

    /// Stacked form cards keep the form width at the regular tier.
    private var formCardCap: CGFloat {
        layout == .regular ? SliveTheme.formWidth : .infinity
    }

    private var captureCard: some View {
        CaptureCard(settings: env.settings, store: store)
    }

    private var groundTruthCard: some View {
        GroundTruthCard(settings: env.settings, providers: env.providers, run: env.labelRun,
                        store: store, transcription: env.transcription,
                        promptClient: env.promptClient,
                        openModels: openModels, onJump: jumpToWayOff)
    }

    /// Move to the page containing a flagged sample before asking the root
    /// scroll view to reveal it. The async hop lets SwiftUI install that page's
    /// row and its `.id` anchor first.
    private func jumpToWayOff(_ id: String) {
        let newestFirst = Array(store.samples.reversed())
        guard let index = newestFirst.firstIndex(where: { $0.id == id }) else { return }
        samplePage = index / DataTableCard.samplesPerPage
        DispatchQueue.main.async { scrollTo(id) }
    }
}
