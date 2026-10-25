import AppKit
import AVFoundation
import SwiftUI

/// The Data page: capture pipeline (CAPTURE), ground-truth transcription
/// (GROUND TRUTH), and the sample browser (DATA) — one scrolling flow, no
/// drill-in. This is the fuel side of fine-tuning; the Training page next
/// door burns it. Renders just its stack; the host supplies scroll and outer
/// width (which lets DATA grow past the form cap at wide sizes).
struct DataSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var store = TrainingStore.shared
    @ObservedObject private var providers = ProviderStore.shared
    /// Every label run lives here, not in this view — it keeps going when
    /// you leave the page or close Settings; the page only observes it.
    @ObservedObject private var run = LabelRun.shared
    private let player = AudioPreviewPlayer.shared
    @Environment(\.sliveLayout) private var layout
    @Environment(\.sliveScrollTo) private var scrollTo
    @Environment(\.slivePreserveScroll) private var preserveScroll
    /// Navigates to the Models page (key entry lives there).
    var openModels: () -> Void = {}

    @State private var confirmClear = false
    @State private var samplePage = 0
    @State private var editingSampleID: String?
    @State private var shouldBeDraft = ""
    /// "Last prompt sent" disclosure (the prompt itself lives in LabelRun).
    @State private var promptExpanded = false
    /// The editable base instruction: draft, fetched default, editor state.
    @State private var editorExpanded = false
    @State private var promptDraft = ""
    @State private var defaultPrompt: String?
    @State private var editorNote: String?

    /// Keep the table bounded: the audio player's 10 Hz progress updates should
    /// never make SwiftUI reconsider hundreds of transcript/diff rows.
    private let samplesPerPage = 20

    private var pageCount: Int {
        max(1, (store.count + samplesPerPage - 1) / samplesPerPage)
    }

    private var visibleSamples: [EditSample] {
        let newestFirst = Array(store.samples.reversed())
        let safePage = min(samplePage, pageCount - 1)
        let start = safePage * samplesPerPage
        guard start < newestFirst.count else { return [] }
        return Array(newestFirst[start..<min(start + samplesPerPage, newestFirst.count)])
    }

    private var visibleRangeText: String {
        guard store.count > 0 else { return "" }
        let start = samplePage * samplesPerPage + 1
        let end = min(start + samplesPerPage - 1, store.count)
        return "\(start)–\(end) of \(store.count)"
    }

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            if layout == .wide {
                // The one place two columns genuinely pay: the two form cards
                // side by side, the table full-width below.
                HStack(alignment: .top, spacing: SliveTheme.gridGap) {
                    captureCard
                    groundTruthCard
                }
            } else {
                Group {
                    captureCard
                    groundTruthCard
                }
                .frame(maxWidth: layout == .compact ? .infinity : SliveTheme.formWidth)
            }
            dataCard
        }
        .onAppear {
            store.loadSamplesIfNeeded()   // lazy index parse
            run.refreshScope()            // price the one-click run right away
        }
        .onChange(of: store.count) { _, _ in
            samplePage = min(samplePage, pageCount - 1)
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Capture (saving + size cap, one pipeline → one card)

    private var captureCard: some View {
        SettingsCard("CAPTURE") {
            ToggleRow(
                title: "Save dictations (audio + transcript)",
                caption: "Saves once your text has landed — never adds a beat of latency.",
                isOn: $settings.captureEdits
            )
            CardDivider()
            HStack {
                Text("Max size")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Spacer()
                Text(String(format: "%.1f GB", settings.captureMaxGB))
                    .font(SliveTheme.mono(12))
                    .foregroundStyle(SliveTheme.accent)
            }
            Slider(value: $settings.captureMaxGB, in: 0.1...20, step: 0.1)
                .tint(SliveTheme.accent)

            // Usage bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1)).frame(height: 6)
                    Capsule()
                        .fill(store.isOverLimit ? Color.orange : SliveTheme.accent)
                        .frame(width: max(4, geo.size.width * store.usageFraction), height: 6)
                }
                .frame(height: 6)
            }
            .frame(height: 6)

            HStack {
                Text("\(byteText(store.totalBytes)) of \(String(format: "%.1f GB", settings.captureMaxGB)) used")
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if store.isOverLimit {
                    Label("Paused — limit reached", systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                } else if settings.captureEdits {
                    Label("Capturing", systemImage: "record.circle")
                        .foregroundStyle(.green)
                } else {
                    Text("Capture off").foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(SliveTheme.font(11, .semibold))
        }
    }

    // MARK: - Ground truth

    /// Default audio-capable model per provider. (OpenAI's `gpt-4o-audio-preview`
    /// was superseded — `gpt-audio` is the GA audio chat model; accounts without
    /// the legacy preview 404 on it. Whisper defaults to the Accurate judge.)
    private func defaultAudioModel(_ p: AssistantProvider) -> String {
        switch p {
        case .gemini: return "gemini-2.5-flash"
        case .openai: return "gpt-audio"
        case .whisper: return "large-v3"
        default: return ""
        }
    }

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

    /// What a row's redo/Get would use, for help text.
    private var labelerName: String {
        isConsensus ? "3-way consensus" : settings.groundTruthModel
    }

    /// Models fetched live for the current ground-truth provider — the FULL
    /// list, unfiltered, from the shared per-provider cache (ProviderStore).
    /// The user decides what's audio-capable (a non-audio pick fails loudly
    /// with the provider's own error, which beats us guessing wrong by name).
    private var fetchedGTModels: [String] {
        providers.models(for: settings.groundTruthProvider)
    }

    private var missingCount: Int {
        store.samples.filter { $0.llmTranscript == nil && store.audioURL($0) != nil }.count
    }

    private var hasAudioSamples: Bool {
        store.samples.contains { store.audioURL($0) != nil }
    }

    private var audioSampleCount: Int {
        store.samples.filter { store.audioURL($0) != nil }.count
    }

    /// Whether this sample's ground truth disagrees with the output by more
    /// than half — usually not a correction but a model gone wrong (answered
    /// the audio, never received it, wrong row). Worth a human look.
    private func isWayOff(_ sample: EditSample) -> Bool {
        guard let truth = effectiveTruth(sample) else { return false }
        return TranscriptDiffCache.divergence(
            id: sample.id, output: sample.transcript, truth: truth) > 0.5
    }

    private func effectiveTruth(_ sample: EditSample) -> String? {
        if !sample.finalText.isEmpty { return sample.finalText }
        return sample.llmTranscript
    }

    /// Way-off rows in table (newest-first) order — the triangle jumps to the
    /// first of these.
    private var wayOffIDs: [String] {
        store.samples.reversed().filter(isWayOff).map(\.id)
    }

    /// Consensus labels the transcribers disagreed on (agreement < 0.8), in
    /// table order — the ear button jumps to the first.
    private var lookIDs: [String] {
        store.samples.reversed().filter(LabelScope.needsALook).map(\.id)
    }

    private var groundTruthCard: some View {
        SettingsCard("GROUND TRUTH", trailing: {
            // Key presence at a glance; tap to manage keys (or, for Local,
            // downloaded models) in Models.
            Button(action: openModels) {
                if isConsensus {
                    KeyStatusPill(hasKey: providers.hasKey(.openai))
                } else if settings.groundTruthProvider.isLocal || settings.groundTruthProvider == .whisper {
                    OnDevicePill()
                } else {
                    KeyStatusPill(hasKey: providers.hasKey(settings.groundTruthProvider))
                }
            }
            .buttonStyle(.plain)
            .help(isConsensus ? "Uses your OpenAI key from Models"
                  : settings.groundTruthProvider == .whisper
                  ? "Runs fully on this Mac — no key"
                  : settings.groundTruthProvider.isLocal
                  ? "Models are downloaded in Models" : "Keys are managed in Models")
        }) {
            Text(isConsensus
                 ? "gpt-transcribe + Whisper + what Slive typed; keeps the version they agree on."
                 : settings.groundTruthProvider == .whisper
                 ? "A bigger Whisper re-judges your audio on-device — dictate on Tiny, ground-truth with Accurate. No cloud, no key."
                 : "A model with ears re-transcribes your audio into the Should-be column — the answer key Slive learns from.")
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
                    settings.groundTruthModel = defaultAudioModel(p)
                    // Picking Local is explicit intent — list what's
                    // downloaded right away.
                    if p.isLocal && providers.models(for: p).isEmpty {
                        Task { await providers.fetchModels(for: .local) }
                    }
                }
                if isConsensus {
                    Text("Recommended")
                        .font(SliveTheme.font(9, .semibold))
                        .foregroundStyle(SliveTheme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
                if isConsensus || settings.groundTruthProvider == .whisper { Spacer(minLength: 0) }
            }

            if isConsensus {
                consensusControls
            } else {
                singleProviderControls
            }

            if run.isRunning {
                runProgress
            }

            if let err = run.message
                ?? (isConsensus ? nil : providers.fetchError(for: settings.groundTruthProvider)) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(err)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(.orange.opacity(0.95))
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
            if let lastPrompt = run.lastPrompt {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { promptExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
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
                    Text("Your Vocabulary words ride at the end — edit them in Dictation → Vocabulary.")
                        .sliveCaption()
                }
            }
        }
    }

    // MARK: Consensus recipe

    /// One click labels everything: the price and time up front, then the
    /// run's progress; afterwards the follow-ups (retry, rows worth a listen).
    @ViewBuilder private var consensusControls: some View {
        let scope = run.scope
        let hasKey = providers.hasKey(.openai)
        if !hasKey {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Needs your OpenAI key — add it in Models → OpenAI.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.95))
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
                    Label("Label everything · \(scope.count.formatted()) clip\(scope.count == 1 ? "" : "s") · \(LabelEstimate.dollarsText(scope.dollars)) · \(LabelEstimate.durationText(scope.seconds))",
                          systemImage: "wand.and.stars")
                        .font(SliveTheme.font(12, .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SliveTheme.accent)
                .controlSize(.large)
                .disabled(!hasKey)
                .help("Labels every recording without a consensus label or a human edit. Human edits are never touched; stop any time and press again to resume.")
            }

            HStack(spacing: 12) {
                if scope.count == 0 && hasAudioSamples {
                    Label("Everything labeled", systemImage: "checkmark.seal.fill")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(.white.opacity(0.4))
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
                    .tint(.orange)
                    .help("Run the clips the last run couldn't label again")
                }
                followUpJumps
                Spacer(minLength: 0)
            }
        }
    }

    /// Jumps to rows worth a human ear: consensus disagreement and way-off.
    @ViewBuilder private var followUpJumps: some View {
        if !lookIDs.isEmpty {
            Button {
                jumpToWayOff(lookIDs[0])
            } label: {
                Label("\(lookIDs.count) need\(lookIDs.count == 1 ? "s" : "") a look", systemImage: "ear.fill")
                    .font(SliveTheme.font(11, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("The transcribers disagreed on \(lookIDs.count) label\(lookIDs.count == 1 ? "" : "s") — jump to the first and give it a listen")
        }
        // Ground truths that disagree with the output by more than half are
        // usually failures, not corrections — surface the count and jump to
        // the first so they get eyes.
        if !wayOffIDs.isEmpty {
            Button {
                jumpToWayOff(wayOffIDs[0])
            } label: {
                Label("\(wayOffIDs.count) way off", systemImage: "exclamationmark.triangle.fill")
                    .font(SliveTheme.font(11, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("\(wayOffIDs.count) ground truths differ from the output by more than half — jump to the first and check it")
        }
    }

    /// A running label pass: count, thin bar, failures, time left and — for
    /// consensus — how well the transcribers are agreeing. Stop is always here.
    private var runProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(run.isConsensusRun ? "Labeling" : "Transcribing")
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
                .help("Stop after the clips in flight — labels so far are kept")
            }

            GeometryReader { geo in
                let fraction = run.total > 0 ? Double(run.processed) / Double(run.total) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1)).frame(height: 4)
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
                                    .foregroundStyle(.orange.opacity(0.9))
                            }
                        }
                    }
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.textSecondary)
                }
                Text("Keeps going if you close Settings; the Mac stays awake until it's done.")
                    .sliveCaption()
            }
        }
    }

    private func progressDetail(now: Date) -> String {
        var parts: [String] = []
        if !run.failedIDs.isEmpty { parts.append("\(run.failedIDs.count) failed") }
        parts.append("\(LabelEstimate.durationText(run.etaSeconds(now: now))) left")
        return parts.joined(separator: " · ")
    }

    // MARK: Single provider

    @ViewBuilder private var singleProviderControls: some View {
        if settings.groundTruthProvider == .whisper {
            // The SAME picker + download linkage as the dictation model
            // card — status dot, download button, progress, all of it.
            ModelPickerRows(model: $settings.groundTruthModel)
        } else {
            HStack(spacing: 10) {
                // The model id that will be sent, with a trailing chip listing
                // the provider's live (audio-capable) models once fetched — so a
                // wrong guess turns into a pick instead of a 404.
                TextField("model (audio-capable)", text: $settings.groundTruthModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .overlay(alignment: .trailing) {
                        if !fetchedGTModels.isEmpty {
                            Menu {
                                ForEach(fetchedGTModels, id: \.self) { m in
                                    Button(m) { settings.groundTruthModel = m }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
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
                        Task { await providers.fetchModels(for: settings.groundTruthProvider) }
                    } label: {
                        Label("Fetch", systemImage: "arrow.clockwise")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SliveTheme.accent)
                    .help(settings.groundTruthProvider.isLocal
                          ? "List your downloaded models"
                          : "Fetch this provider's live model list")
                }
            }
        }

        if !run.isRunning {
            HStack(spacing: 10) {
                Button {
                    run.runSingle(includeExisting: false)
                } label: {
                    Label("Transcribe missing (\(missingCount))", systemImage: "wand.and.stars")
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
                    Label("Run all (\(audioSampleCount))", systemImage: "arrow.triangle.2.circlepath")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(audioSampleCount == 0)
                .help("Re-transcribe every recording with \(settings.groundTruthModel), replacing existing ground truth")

                // Appears only after a run stopped early — resumes the untouched
                // tail, which "Transcribe missing" can't reach once a Run-all has
                // already given those samples an (old) value.
                if !run.leftoverIDs.isEmpty {
                    Button {
                        run.runRemaining()
                    } label: {
                        Label("Run left (\(run.leftoverIDs.count))", systemImage: "arrow.uturn.left")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Resume where the last run stopped — only the \(run.leftoverIDs.count) it didn't reach")
                }

                followUpJumps

                if missingCount == 0 && hasAudioSamples {
                    Label("All caught up", systemImage: "checkmark.seal.fill")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
        }

        // The EDITABLE base instruction for Should-be generation. Your edit
        // owns the instruction; the vocabulary tail below is always rebuilt
        // LIVE from Dictation → Vocabulary and appended server-side — updated
        // custom words flow in without touching the base you saved.
        if settings.groundTruthProvider != .whisper {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { editorExpanded.toggle() }
                if editorExpanded { loadEditor() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(editorExpanded ? 90 : 0))
                    Text("Transcription prompt")
                        .font(SliveTheme.font(11, .semibold))
                    Text(settings.groundTruthPrompt.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty
                         ? "Default" : "Customized")
                        .font(SliveTheme.font(9, .semibold))
                        .foregroundStyle(settings.groundTruthPrompt.isEmpty
                                         ? SliveTheme.textTertiary : SliveTheme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.07)))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(SliveTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if editorExpanded {
                TextEditor(text: $promptDraft)
                    .font(SliveTheme.mono(11))
                    .foregroundStyle(.white.opacity(0.85))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 130)
                    .innerWell()
                HStack(spacing: 10) {
                    Button("Save") { saveEditor() }
                        .buttonStyle(.borderedProminent)
                        .tint(SliveTheme.accent)
                        .controlSize(.small)
                    Button("Reset to default") { resetEditor() }
                        .buttonStyle(.plain)
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(SliveTheme.accent)
                    if let editorNote {
                        Text(editorNote)
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
                    .foregroundStyle(SliveTheme.accent.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .innerWell()
                Text("This tail repopulates automatically from Dictation → Vocabulary and is appended to whatever base you save — edit the words there, not here.")
                    .sliveCaption()
            }
        }
    }

    // MARK: - Prompt editor (the editable base instruction)

    /// Populate the editor: the saved custom base, else the server default
    /// (fetched once; the backend spins up lazily on first use).
    private func loadEditor() {
        let custom = settings.groundTruthPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { promptDraft = custom; return }
        if let defaultPrompt { promptDraft = defaultPrompt; return }
        editorNote = "loading default…"
        Task { @MainActor in
            defer { editorNote = nil }
            if let fetched = try? await GroundTruthClient().defaultPrompt() {
                defaultPrompt = fetched
                if promptDraft.isEmpty { promptDraft = fetched }
            } else {
                editorNote = "couldn't load the default — type your own or retry"
            }
        }
    }

    /// Save: a draft identical to the default is stored as EMPTY so future
    /// server-side default improvements keep flowing; anything else is the
    /// user's custom base.
    private func saveEditor() {
        let draft = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || draft == defaultPrompt {
            settings.groundTruthPrompt = ""
            editorNote = "following the default"
        } else {
            settings.groundTruthPrompt = draft
            editorNote = "saved — applies to the next generation"
        }
    }

    private func resetEditor() {
        settings.groundTruthPrompt = ""
        promptDraft = defaultPrompt ?? ""
        editorNote = "reset to default"
        if defaultPrompt == nil { loadEditor() }
    }

    /// Move to the page containing a flagged sample before asking the root
    /// scroll view to reveal it. The async hop lets SwiftUI install that page's
    /// row and its `.id` anchor first.
    private func jumpToWayOff(_ id: String) {
        let newestFirst = Array(store.samples.reversed())
        guard let index = newestFirst.firstIndex(where: { $0.id == id }) else { return }
        samplePage = index / samplesPerPage
        DispatchQueue.main.async { scrollTo(id) }
    }

    // MARK: - Data table

    private var dataCard: some View {
        SettingsCard("DATA", trailing: {
            HStack(spacing: 12) {
                Text("\(store.count) sample\(store.count == 1 ? "" : "s") · \(byteText(store.totalBytes))")
                    .font(SliveTheme.font(12))
                    .foregroundStyle(.white.opacity(0.55))
                if !store.samples.isEmpty {
                    Button("Clear all") { confirmClear = true }
                        .buttonStyle(.plain)
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }) {
            if store.samples.isEmpty {
                EmptyState(
                    icon: "waveform",
                    title: "No samples yet",
                    caption: "Flip on Capture above and start dictating — each row is one take: the audio, what Slive wrote, and what it should've been."
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    tableHeaderRow
                    Divider().overlay(.white.opacity(0.1))
                    // Newest first, one bounded page at a time. `.id` anchors
                    // the way-off jump after it switches to the target page.
                    ForEach(visibleSamples) { sample in
                        dataRow(sample)
                            .id(sample.id)
                        Divider().overlay(.white.opacity(0.06))
                    }
                    if pageCount > 1 {
                        paginationControls
                            .padding(.top, 12)
                    }
                }
            }
        }
        .confirmationDialog("Delete \(store.count) sample\(store.count == 1 ? "" : "s")?",
                            isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                store.clearAll()
                TranscriptDiffCache.clear()
                samplePage = 0
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var paginationControls: some View {
        HStack(spacing: 12) {
            Button {
                player.stop()
                preserveScroll {
                    samplePage = max(0, samplePage - 1)
                }
            } label: {
                Label("Newer", systemImage: "chevron.left")
            }
            .disabled(samplePage == 0)

            Spacer()
            Text(visibleRangeText)
                .font(SliveTheme.mono(11))
                .foregroundStyle(SliveTheme.textSecondary)
            Spacer()

            Button {
                player.stop()
                preserveScroll {
                    samplePage = min(pageCount - 1, samplePage + 1)
                }
            } label: {
                Label("Older", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(samplePage >= pageCount - 1)
        }
        .font(SliveTheme.font(11, .semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Text columns cap at ~67 characters so the table stays readable at the
    /// wide tier instead of stretching into prairie-wide lines.
    private let textColumnCap: CGFloat = 420

    private var tableHeaderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("AUDIO").frame(width: 40, alignment: .leading)
            Text("OUTPUT").frame(maxWidth: textColumnCap, alignment: .leading)
            Text("SHOULD BE").frame(maxWidth: textColumnCap, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(SliveTheme.font(10, .bold))
        .foregroundStyle(.white.opacity(0.4))
        .tracking(0.8)
        .padding(.bottom, 8)
    }

    private func dataRow(_ sample: EditSample) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                // Audio column: play/pause toggles the shared player onto this row.
                DataAudioButton(sampleID: sample.id, url: store.audioURL(sample))
                .frame(width: 40, alignment: .leading)

                // What Slive output.
                Text(sample.transcript)
                    .font(SliveTheme.font(12))
                    .foregroundStyle(SliveTheme.textMid)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: textColumnCap, alignment: .leading)

                // What it should have been — corrected words highlighted.
                shouldBeCell(sample)
                    .font(SliveTheme.font(12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: textColumnCap, alignment: .leading)

                Spacer(minLength: 8)

                // Drop this one sample (audio + row).
                Button {
                    if player.currentID == sample.id { player.stop() }
                    if editingSampleID == sample.id { editingSampleID = nil }
                    TranscriptDiffCache.remove(id: sample.id)
                    store.remove(id: sample.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help("Delete this sample")
            }

            DataPlaybackScrubber(sampleID: sample.id)
        }
        .padding(.vertical, 9)
    }

    /// SHOULD BE cell states: inline human editor → manual correction →
    /// word-diffed model transcript → spinner → Get/Edit actions → dash.
    @ViewBuilder private func shouldBeCell(_ sample: EditSample) -> some View {
        if editingSampleID == sample.id {
            shouldBeEditor(sample)
        } else if run.inFlight.contains(sample.id) {
            ProgressView().controlSize(.small)
        } else if let truth = effectiveTruth(sample) {
            HStack(alignment: .top, spacing: 6) {
                truthTextView(truth, sample: sample)
                if !sample.finalText.isEmpty {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .help("Human edited — this label takes priority for training")
                }
                // >50% divergence is rarely a correction — flag it for a
                // human ear (listen, then redo or leave it).
                if isWayOff(sample) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("Differs from the output by more than half — listen and redo if the model went wrong")
                }
                // The consensus transcribers disagreed — the label is their
                // best guess; a listen (and the pencil) settles it.
                if LabelScope.needsALook(sample) {
                    Image(systemName: "ear.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("The transcribers only agreed \(Int(((sample.llmAgreement ?? 0) * 100).rounded()))% — give it a listen")
                }
                if sample.finalText.isEmpty, sample.llmTranscript != nil {
                    // Redo the model label. A human edit, once present, remains
                    // authoritative and is never silently replaced.
                    Button { run.labelOne(sample) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("Re-label with \(labelerName)")
                }
                Button { beginShouldBeEdit(sample) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SliveTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Edit Should be")
            }
        } else if store.audioURL(sample) != nil {
            HStack(spacing: 8) {
                Button { run.labelOne(sample) } label: {
                    Label("Get", systemImage: "wand.and.stars")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Label with \(labelerName)")
                Button { beginShouldBeEdit(sample) } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SliveTheme.accent)
                .help("Write the correct transcript yourself")
            }
        } else {
            Text("—").foregroundStyle(.white.opacity(0.4))
        }
    }

    private func beginShouldBeEdit(_ sample: EditSample) {
        shouldBeDraft = effectiveTruth(sample) ?? sample.transcript
        editingSampleID = sample.id
    }

    private func saveShouldBeEdit(_ sample: EditSample) {
        let cleaned = shouldBeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        TranscriptDiffCache.remove(id: sample.id)
        store.setManualTranscript(id: sample.id, text: cleaned)
        editingSampleID = nil
        shouldBeDraft = ""
    }

    private func shouldBeEditor(_ sample: EditSample) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: $shouldBeDraft)
                .font(SliveTheme.font(12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 72, maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SliveTheme.wellFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(SliveTheme.accent.opacity(0.45), lineWidth: 1)
                        )
                )
            HStack(spacing: 8) {
                Button("Save") { saveShouldBeEdit(sample) }
                    .buttonStyle(.borderedProminent)
                    .tint(SliveTheme.accent)
                    .disabled(shouldBeDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    editingSampleID = nil
                    shouldBeDraft = ""
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.mini)
        }
    }

    /// The word-diffed effective truth (whole-string fallback for over-length
    /// corrections; deletions render as an underline on the neighboring word).
    @ViewBuilder private func truthTextView(_ truth: String, sample: EditSample) -> some View {
        if let diffed = TranscriptDiffCache.styled(
            id: sample.id, output: sample.transcript, truth: truth,
            base: .white.opacity(0.75), changed: .orange.opacity(0.95)) {
            Text(diffed).textSelection(.enabled)
        } else {
            Text(truth)
                .foregroundStyle(truth == sample.transcript
                                 ? .white.opacity(0.75) : .orange.opacity(0.95))
                .textSelection(.enabled)
        }
    }

    // MARK: - Shared

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Playback observation lives in these tiny row-local views. The 10 Hz ticker
/// therefore refreshes the controls, not the whole Data page and every diff.
private struct DataAudioButton: View {
    let sampleID: String
    let url: URL?
    @ObservedObject private var player = AudioPreviewPlayer.shared

    var body: some View {
        if let url {
            Button { player.toggle(id: sampleID, url: url) } label: {
                Image(systemName: player.currentID == sampleID && player.isPlaying
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(SliveTheme.accent)
            }
            .buttonStyle(.plain)
            .help(player.currentID == sampleID && player.isPlaying ? "Pause" : "Play")
        } else {
            Image(systemName: "waveform.slash")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}

private struct DataPlaybackScrubber: View {
    let sampleID: String
    @ObservedObject private var player = AudioPreviewPlayer.shared

    var body: some View {
        if player.currentID == sampleID {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { player.position },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.01)
                )
                .controlSize(.mini)
                .tint(SliveTheme.accent)
                .frame(maxWidth: 220)
                Text("\(AudioPreviewPlayer.timeText(player.position)) / \(AudioPreviewPlayer.timeText(player.duration))")
                    .font(SliveTheme.mono(10))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            }
            .padding(.leading, 52)
            .padding(.horizontal, -8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.04))
            )
        }
    }
}
