import SwiftUI

// MARK: - Ground truth

/// GROUND TRUTH: pick the labeler (the 3-way consensus recipe or one
/// provider), run it, see what went in.
struct GroundTruthCard: View {
    @ObservedObject var settings: Settings
    @ObservedObject var providers: ProviderStore
    /// Every label run lives in LabelRun, not in this view — it keeps going
    /// when you leave the page or close Settings; the card only observes it.
    @ObservedObject var run: LabelRun
    let store: TrainingStore
    let transcription: TranscriptionModel
    /// Navigates to the Models page (key entry lives there).
    let openModels: () -> Void
    /// Reveal a flagged sample in the table below.
    let onJump: (String) -> Void

    /// "Last prompt sent" disclosure (the prompt itself lives in LabelRun).
    @State private var promptExpanded = false
    /// The editable base instruction: draft, fetched default, editor state.
    @State private var editorExpanded = false
    @StateObject private var prompt: GroundTruthPromptModel
    @State private var consensusExpanded = false
    @State private var consensusDraft = ""
    @State private var consensusNote: String?

    init(settings: Settings, providers: ProviderStore, run: LabelRun, store: TrainingStore,
         transcription: TranscriptionModel, promptClient: GroundTruthPromptClient,
         openModels: @escaping () -> Void, onJump: @escaping (String) -> Void) {
        _settings = ObservedObject(wrappedValue: settings)
        _providers = ObservedObject(wrappedValue: providers)
        _run = ObservedObject(wrappedValue: run)
        self.store = store
        self.transcription = transcription
        _prompt = StateObject(wrappedValue: GroundTruthPromptModel(settings: settings, client: promptClient))
        self.openModels = openModels
        self.onJump = onJump
    }

    /// The consensus recipe's key (OpenAI) — a catalog constant, not a literal.
    private let consensusKey = ProviderCatalog.consensusKeyProvider

    /// The 3-way consensus recipe is selected (the default).
    private var isConsensus: Bool { settings.groundTruthRecipe == .consensus }

    /// The picker's selection: the consensus recipe, or one provider.
    private var sourceBinding: Binding<GroundTruthSource> {
        Binding(
            get: { isConsensus ? .consensus : .provider(settings.groundTruthProvider) },
            set: { source in
                switch source {
                case .consensus:
                    settings.groundTruthRecipe = .consensus
                case .provider(let p):
                    settings.groundTruthRecipe = .single
                    if p != settings.groundTruthProvider { settings.groundTruthProvider = p }
                }
            })
    }

    var body: some View {
        SettingsCard("GROUND TRUTH", trailing: {
            // Key presence at a glance; tap to manage keys (or, for Local,
            // downloaded models) in Models.
            Button(action: openModels) {
                if isConsensus {
                    KeyStatusPill(hasKey: providers.hasKey(consensusKey))
                } else if settings.groundTruthProvider.runsOnDevice {
                    OnDevicePill()
                } else {
                    KeyStatusPill(hasKey: providers.hasKey(settings.groundTruthProvider))
                }
            }
            .buttonStyle(.plain)
            .help(isConsensus ? "Manage keys"
                  : settings.groundTruthProvider == .whisper
                  ? "On this Mac"
                  : settings.groundTruthProvider.isLocal
                  ? "Manage models" : "Manage keys")
        }) {
            Text(isConsensus
                 ? "gpt-transcribe labels; 2 others check."
                 : settings.groundTruthProvider == .whisper
                 ? "On this Mac."
                 : "Writes the Correct column.")
                .sliveCaption()

            HStack(spacing: 10) {
                Picker("", selection: sourceBinding) {
                    Text(GroundTruthSource.consensus.title).tag(GroundTruthSource.consensus)
                    Divider()
                    ForEach(GroundTruthSource.singleProviders) { p in
                        Text(p.displayName).tag(GroundTruthSource.provider(p))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
                .disabled(run.isRunning)
                .onChange(of: settings.groundTruthProvider) { _, p in
                    settings.groundTruthModel = p.groundTruthDefaultModel
                    // Picking Local is explicit intent — list what's
                    // downloaded right away.
                    if p.isLocal { providers.requestModels(for: .local, onlyIfEmpty: true) }
                }
                if isConsensus || settings.groundTruthProvider == .whisper { Spacer(minLength: 0) }
            }

            if isConsensus {
                ConsensusControls(run: run, providers: providers, store: store,
                                  openModels: openModels, onJump: onJump)
                ConsensusPromptEditor(settings: settings, run: run, expanded: $consensusExpanded,
                                      draft: $consensusDraft, note: $consensusNote)
            } else {
                SingleProviderControls(settings: settings, providers: providers, run: run,
                                       store: store, transcription: transcription, onJump: onJump)
                // The EDITABLE base instruction for Should-be generation.
                if settings.groundTruthProvider != .whisper {
                    GroundTruthPromptEditor(settings: settings, prompt: prompt,
                                            expanded: $editorExpanded)
                }
            }

            if run.isRunning {
                LabelRunProgress(run: run)
            }

            if let err = run.message
                ?? (isConsensus ? nil : providers.fetchError(for: settings.groundTruthProvider)) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(err)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.warnStrong)
                        .fixedSize(horizontal: false, vertical: true)
                    if run.needsKeyFix {
                        Spacer(minLength: 0)
                        Button("Open Models", action: openModels)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(SliveTheme.accent)
                            .fixedSize()
                    }
                }
            }

            // What actually went in: the exact instruction the most recent
            // generation was seeded with — vocabulary visible at its tail,
            // so "are my words in there?" is a look, not a guess.
            if settings.verboseLogging, let lastPrompt = run.lastPrompt {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { promptExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(SliveTheme.badgeFont)
                            .rotationEffect(.degrees(promptExpanded ? 90 : 0))
                        Text("Last prompt sent")
                            .font(SliveTheme.font(11, .semibold))
                        if let meta = run.lastPromptMeta {
                            Text(meta)
                                .font(SliveTheme.mono(10))
                                .foregroundStyle(SliveTheme.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(SliveTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if promptExpanded {
                    ScrollView {
                        Text(lastPrompt)
                            .font(SliveTheme.mono(10.5))
                            .foregroundStyle(SliveTheme.textMid)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 170)
                    .innerWell()
                }
            }
        }
    }
}

// MARK: Single provider

/// One provider labels: its model (picked or typed), then label / redo /
/// resume.
struct SingleProviderControls: View {
    @ObservedObject var settings: Settings
    @ObservedObject var providers: ProviderStore
    @ObservedObject var run: LabelRun
    @ObservedObject var store: TrainingStore
    /// For the Whisper judge's model picker.
    let transcription: TranscriptionModel
    let onJump: (String) -> Void

    /// Models fetched live for the current ground-truth provider — the FULL
    /// list, unfiltered, from the shared per-provider cache (ProviderStore).
    /// The user decides what's audio-capable (a non-audio pick fails loudly
    /// with the provider's own error, which beats us guessing wrong by name).
    private var fetchedGTModels: [String] {
        providers.models(for: settings.groundTruthProvider)
    }

    // Counts and jump lists come from the store's per-change memo — this
    // page re-renders at 10 Hz during playback, and recounting meant a stat
    // per sample per redraw.
    private var missingCount: Int { store.summary.missingCount }

    private var hasAudioSamples: Bool { store.summary.audioCount > 0 }

    private var audioSampleCount: Int { store.summary.audioCount }

    var body: some View {
        if settings.groundTruthProvider == .whisper {
            // The SAME picker + download linkage as the dictation model
            // card — status dot, download button, progress, all of it.
            ModelPickerRows(model: $settings.groundTruthModel, transcription: transcription, use: .groundTruth)
        } else {
            HStack(spacing: 10) {
                // The model id that will be sent, with a trailing chip listing
                // the provider's live (audio-capable) models once fetched — so a
                // wrong guess turns into a pick instead of a 404.
                TextField("Model", text: $settings.groundTruthModel)
                    .textFieldStyle(.roundedBorder)
                    .font(SliveTheme.monoBody)
                    .overlay(alignment: .trailing) {
                        if !fetchedGTModels.isEmpty {
                            Menu {
                                ForEach(fetchedGTModels, id: \.self) { m in
                                    Button(m) { settings.groundTruthModel = m }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(SliveTheme.tagFont)
                                    .foregroundStyle(SliveTheme.accent)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .padding(.trailing, 6)
                        }
                    }

                if providers.isFetching(settings.groundTruthProvider) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        providers.requestModels(for: settings.groundTruthProvider)
                    } label: {
                        Label("Fetch", systemImage: "arrow.clockwise")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SliveTheme.accent)
                }
            }
        }

        if !run.isRunning {
            HStack(spacing: 10) {
                Button {
                    run.runSingle(includeExisting: false)
                } label: {
                    Label("Label \(missingCount) missing", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(SliveTheme.accent)
                .controlSize(.small)
                .disabled(missingCount == 0)

                // Re-run every recording with the currently selected model —
                // replaces existing Should-be values (e.g. after switching to
                // a better model).
                Button {
                    run.runSingle(includeExisting: true)
                } label: {
                    Label("Redo all", systemImage: "arrow.triangle.2.circlepath")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(audioSampleCount == 0)
                .help("Replaces all labels")

                // Appears only after a run stopped early — resumes the untouched
                // tail, which "Transcribe missing" can't reach once a Run-all has
                // already given those samples an (old) value.
                if !run.leftoverIDs.isEmpty {
                    Button {
                        run.runRemaining()
                    } label: {
                        Label("Resume \(run.leftoverIDs.count)", systemImage: "arrow.uturn.left")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(SliveTheme.warn)
                }

                FollowUpJumps(store: store, onJump: onJump)

                if missingCount == 0 && hasAudioSamples {
                    Label("All labeled", systemImage: "checkmark.seal.fill")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(SliveTheme.textFaint)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Rows worth a human ear (consensus disagreement, way off), as one jump.
struct FollowUpJumps: View {
    @ObservedObject var store: TrainingStore
    let onJump: (String) -> Void

    var body: some View {
        let ids = store.summary.checkIDs
        if let first = ids.first {
            Button {
                onJump(first)
            } label: {
                Label("\(ids.count) to check", systemImage: "ear.fill")
                    .font(SliveTheme.font(11, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SliveTheme.warn)
            .help("Low agreement or far from output")
        }
    }
}

/// A running label pass: count, thin bar, failures, time left and — for
/// consensus — how well the transcribers are agreeing. Stop is always here.
struct LabelRunProgress: View {
    @ObservedObject var run: LabelRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Labeling")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Text("\(run.done.formatted()) / \(run.total.formatted())")
                    .font(SliveTheme.mono(12))
                    .foregroundStyle(SliveTheme.accent)
                Spacer(minLength: 0)
                Button {
                    run.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            GeometryReader { geo in
                let fraction = run.total > 0 ? Double(run.processed) / Double(run.total) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(SliveTheme.trackFill).frame(height: 4)
                    Capsule()
                        .fill(SliveTheme.accent)
                        .frame(width: max(4, geo.size.width * min(1, fraction)), height: 4)
                }
                .frame(height: 4)
            }
            .frame(height: 4)

            if run.isConsensusRun {
                // Ticks once a second so the time left counts down between clips.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Text(progressDetail(now: context.date))
                        Spacer(minLength: 0)
                        if let mean = run.agreementMean {
                            Text("agreement \(Int((mean * 100).rounded()))%")
                            if run.lowAgreementCount > 0 {
                                Text("· \(run.lowAgreementCount) low")
                                    .foregroundStyle(SliveTheme.warnText)
                            }
                        }
                    }
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.textSecondary)
                }
            }
        }
    }

    private func progressDetail(now: Date) -> String {
        var parts: [String] = []
        if !run.failedIDs.isEmpty { parts.append("\(run.failedIDs.count) failed") }
        parts.append("\(LabelEstimate.durationText(run.etaSeconds(now: now))) left")
        return parts.joined(separator: " · ")
    }
}
