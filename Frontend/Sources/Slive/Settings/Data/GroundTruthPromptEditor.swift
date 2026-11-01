import SwiftUI

/// Where the server's default label instruction comes from —
/// `GroundTruthClient` in the app, a fake in the self-test.
protocol GroundTruthPromptClient {
    func defaultPrompt() async throws -> String
}

extension GroundTruthClient: GroundTruthPromptClient {}

/// The editable base instruction for single-provider Should-be generation:
/// the draft, the server's default (fetched once) and the note beside Save.
@MainActor
final class GroundTruthPromptModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var defaultPrompt: String?
    @Published private(set) var note: String?

    private let settings: Settings
    private let client: GroundTruthPromptClient

    init(settings: Settings, client: GroundTruthPromptClient) {
        self.settings = settings
        self.client = client
    }

    /// Populate the editor: the saved custom base, else the server default
    /// (fetched once; the backend spins up lazily on first use).
    func load() {
        let custom = settings.groundTruthPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { draft = custom; return }
        if let defaultPrompt { draft = defaultPrompt; return }
        note = "Loading…"
        let client = client
        Task { @MainActor in
            if let fetched = try? await client.defaultPrompt() {
                defaultPrompt = fetched
                if draft.isEmpty { draft = fetched }
                note = nil
            } else {
                note = "Couldn't load default."
            }
        }
    }

    /// Save: a draft identical to the default is stored as EMPTY so future
    /// server-side default improvements keep flowing; anything else is the
    /// user's custom base.
    func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == defaultPrompt {
            settings.groundTruthPrompt = ""
            note = nil
        } else {
            settings.groundTruthPrompt = trimmed
            note = "Saved"
        }
    }

    func reset() {
        settings.groundTruthPrompt = ""
        draft = defaultPrompt ?? ""
        note = nil
        if defaultPrompt == nil { load() }
    }
}

/// The EDITABLE base instruction for Should-be generation. Your edit
/// owns the instruction; the vocabulary tail below is always rebuilt
/// LIVE from Dictation → Vocabulary and appended server-side — updated
/// custom words flow in without touching the base you saved.
struct GroundTruthPromptEditor: View {
    @ObservedObject var settings: Settings
    @ObservedObject var prompt: GroundTruthPromptModel
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            if expanded { prompt.load() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(SliveTheme.badgeFont)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Transcription prompt")
                    .font(SliveTheme.font(11, .semibold))
                Text(settings.groundTruthPrompt.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                     ? "Default" : "Customized")
                    .font(SliveTheme.font(9, .semibold))
                    .foregroundStyle(settings.groundTruthPrompt.isEmpty
                                     ? SliveTheme.textTertiary : SliveTheme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(SliveTheme.chipFill))
                Spacer(minLength: 0)
            }
            .foregroundStyle(SliveTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if expanded {
            TextEditor(text: $prompt.draft)
                .font(SliveTheme.mono(11))
                .foregroundStyle(SliveTheme.textHigh)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 130)
                .innerWell()
            HStack(spacing: 10) {
                Button("Save") { prompt.save() }
                    .buttonStyle(.borderedProminent)
                    .tint(SliveTheme.accent)
                    .controlSize(.small)
                Button("Reset to default") { prompt.reset() }
                    .buttonStyle(.plain)
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.accent)
                if let note = prompt.note {
                    Text(note)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            // The live vocabulary tail — always appended, never part of
            // the editable base, so updated custom words flow in.
            Text(GroundTruthClient.vocabHint(
                    hotwords: settings.hotwords, context: settings.contextPrompt)
                 ?? "(no custom words set)")
                .font(SliveTheme.mono(10))
                .foregroundStyle(SliveTheme.accentMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .innerWell()
            Text("+ Vocabulary words")
                .sliveCaption()
        }
    }
}
