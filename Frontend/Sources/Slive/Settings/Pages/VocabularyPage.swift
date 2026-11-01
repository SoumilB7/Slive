import SwiftUI

extension SettingsPageID {
    static let vocabulary = SettingsPageID("vocabulary")
}

extension SettingsPageSpec {
    static let vocabulary = SettingsPageSpec(
        id: .vocabulary, title: "Vocabulary", icon: "character.book.closed.fill", section: .library
    ) { ctx in
        AnyView(VocabularyPage(settings: ctx.env.settings))
    }
}

/// Dictation · Vocabulary.
struct VocabularyPage: View {
    @ObservedObject var settings: Settings
    @Environment(\.sliveLayout) private var layout

    var body: some View {
        SettingsCard("") {
            if layout == .wide {
                HStack(alignment: .top, spacing: 16) {
                    VocabularyField(label: "Custom words", hint: "One per line",
                                    height: 96, text: $settings.hotwords)
                    VocabularyField(label: "Context prompt", hint: "Context for labels",
                                    height: 96, text: $settings.contextPrompt)
                }
            } else {
                VocabularyField(label: "Custom words", hint: "One per line",
                                height: 96, text: $settings.hotwords)
                VocabularyField(label: "Context prompt", hint: "Context for labels",
                                height: 72, text: $settings.contextPrompt)
            }
        }
    }
}

// MARK: - Vocabulary field (focus ring on the well)

private struct VocabularyField: View {
    let label: String
    let hint: String
    let height: CGFloat
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(SliveTheme.rowFont)
                .foregroundStyle(SliveTheme.textPrimary)
            TextEditor(text: $text)
                .font(SliveTheme.font(12))
                .foregroundStyle(SliveTheme.textBright)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: SliveTheme.fieldRadius, style: .continuous)
                        .fill(SliveTheme.wellFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: SliveTheme.fieldRadius, style: .continuous)
                                .strokeBorder(
                                    focused ? SliveTheme.accentFocus : SliveTheme.wellStroke,
                                    lineWidth: focused ? 1 : 0.8)
                        )
                )
                .focused($focused)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
        .help(hint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
