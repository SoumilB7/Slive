import SwiftUI

// MARK: Consensus recipe

/// One click labels everything: the price and time up front, then the
/// run's progress; afterwards the follow-ups (retry, rows worth a listen).
struct ConsensusControls: View {
    @ObservedObject var run: LabelRun
    @ObservedObject var providers: ProviderStore
    @ObservedObject var store: TrainingStore
    let openModels: () -> Void
    let onJump: (String) -> Void

    /// The consensus recipe's key (OpenAI) — a catalog constant, not a literal.
    private let consensusKey = ProviderCatalog.consensusKeyProvider

    var body: some View {
        let scope = run.scope
        let hasKey = providers.hasKey(consensusKey)
        if !hasKey {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Add an OpenAI key to try the 3-way check.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.warnStrong)
                Spacer(minLength: 0)
                Button("Add key", action: openModels)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(SliveTheme.accent)
                    .fixedSize()
            }
        }

        if !run.isRunning {
            if scope.count > 0 {
                Button {
                    run.labelEverything()
                } label: {
                    Label("Label \(scope.count.formatted()) · \(LabelEstimate.dollarsText(scope.dollars)) · \(LabelEstimate.durationText(scope.seconds))",
                          systemImage: "wand.and.stars")
                        .font(SliveTheme.font(12, .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SliveTheme.accent)
                .controlSize(.large)
                .disabled(!hasKey)
                .help("Skips your edits. Resumable.")
            }

            HStack(spacing: 12) {
                if scope.count == 0 && store.summary.audioCount > 0 {
                    Label("All labeled", systemImage: "checkmark.seal.fill")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(SliveTheme.textFaint)
                }
                if !run.failedIDs.isEmpty {
                    Button {
                        run.retryFailed()
                    } label: {
                        Label("Retry \(run.failedIDs.count) failed", systemImage: "arrow.uturn.left")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(SliveTheme.warn)
                }
                FollowUpJumps(store: store, onJump: onJump)
                Spacer(minLength: 0)
            }
        }
    }
}

/// What gpt-transcribe is told, before any run: the editable speaker
/// line, then (live, read-only) the Vocabulary context and keywords.
struct ConsensusPromptEditor: View {
    @ObservedObject var settings: Settings
    @ObservedObject var run: LabelRun
    @Binding var expanded: Bool
    @Binding var draft: String
    @Binding var note: String?

    var body: some View {
        let custom = !settings.consensusPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            if expanded {
                draft = custom ? settings.consensusPrompt : GroundTruthClient.consensusDefaultBase
                note = nil
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(SliveTheme.badgeFont)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Transcription prompt")
                    .font(SliveTheme.font(11, .semibold))
                Text(custom ? "Customized" : "Default")
                    .font(SliveTheme.font(9, .semibold))
                    .foregroundStyle(custom ? SliveTheme.accent : SliveTheme.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(SliveTheme.chipFill))
                Spacer(minLength: 0)
            }
            .foregroundStyle(SliveTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if expanded {
            TextEditor(text: $draft)
                .font(SliveTheme.mono(11))
                .foregroundStyle(SliveTheme.textHigh)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 64)
                .innerWell()
            HStack(spacing: 10) {
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.consensusPrompt = trimmed == GroundTruthClient.consensusDefaultBase ? "" : trimmed
                    note = "Saved"
                }
                .buttonStyle(.borderedProminent)
                .tint(SliveTheme.accent)
                .controlSize(.small)
                .disabled(run.isRunning)
                Button("Reset to default") {
                    settings.consensusPrompt = ""
                    draft = GroundTruthClient.consensusDefaultBase
                    note = nil
                }
                .buttonStyle(.plain)
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(SliveTheme.accent)
                if let note {
                    Text(note)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            // Exactly what one clip sends — live from Vocabulary.
            let keywords = GroundTruthClient.consensusKeywords(settings.hotwords)
            Text(GroundTruthClient.consensusPrompt(base: settings.consensusPrompt,
                                                   context: settings.contextPrompt)
                 + "\nKeywords: " + (keywords.isEmpty ? "none" : keywords.joined(separator: ", ")))
                .font(SliveTheme.mono(10))
                .foregroundStyle(SliveTheme.accentMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .innerWell()
            Text("+ Vocabulary context and words")
                .sliveCaption()
        }
    }
}
