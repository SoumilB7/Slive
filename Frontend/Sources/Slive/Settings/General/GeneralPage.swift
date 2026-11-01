import SwiftUI

extension SettingsPageID {
    static let general = SettingsPageID("general")
}

extension SettingsPageSpec {
    static let general = SettingsPageSpec(
        id: .general, title: "General", icon: "gearshape.fill", section: .app,
        width: .grid,
        status: { env in .model(env.settings.whisperModel, env.transcription) }
    ) { ctx in
        AnyView(GeneralPage(env: ctx.env))
    }
}

/// The General page's cards, in narrow-layout order. The wide layout reads
/// the same list, split by `column`: setup on the left, model and mic on the
/// right, the speed graph full width below.
enum GeneralCard: CaseIterable {
    case keys, liveTyping, model, microphone, behavior, overlay, speed

    enum Column { case left, right, full }

    var column: Column {
        switch self {
        case .keys, .liveTyping, .behavior: return .left
        case .model, .microphone, .overlay: return .right
        case .speed: return .full
        }
    }

    static func cards(in column: Column) -> [GeneralCard] {
        allCases.filter { $0.column == column }
    }
}

/// Dictation · General.
struct GeneralPage: View {
    let env: SettingsEnv
    @ObservedObject private var settings: Settings
    @Environment(\.sliveLayout) private var layout

    init(env: SettingsEnv) {
        self.env = env
        _settings = ObservedObject(wrappedValue: env.settings)
    }

    var body: some View {
        Group {
            if layout == .wide {
                VStack(spacing: SliveTheme.cardGap) {
                    HStack(alignment: .top, spacing: SliveTheme.gridGap) {
                        column(.left)
                        column(.right)
                    }
                    ForEach(GeneralCard.cards(in: .full), id: \.self) { card($0) }
                }
            } else {
                VStack(spacing: SliveTheme.cardGap) {
                    ForEach(GeneralCard.allCases, id: \.self) { card($0) }
                }
            }
        }
        .onAppear { env.transcription.select(settings.whisperModel) }
        .onChange(of: settings.whisperModel) { _, m in env.transcription.select(m) }
    }

    private func column(_ column: GeneralCard.Column) -> some View {
        VStack(spacing: SliveTheme.cardGap) {
            ForEach(GeneralCard.cards(in: column), id: \.self) { card($0) }
        }
    }

    @ViewBuilder private func card(_ card: GeneralCard) -> some View {
        switch card {
        case .keys: KeysCard(settings: env.settings)
        case .liveTyping: LiveTypingSuggestionCard(settings: env.settings, transcription: env.transcription)
        case .model: DictationModelCard(settings: env.settings, transcription: env.transcription)
        case .microphone: MicrophoneCard(settings: env.settings, inputDevices: env.inputDevices)
        case .behavior: BehaviorCard(settings: env.settings)
        case .overlay: OverlayCard(settings: env.settings)
        case .speed: SpeedCard(settings: env.settings, transcription: env.transcription)
        }
    }
}
