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
    private let player = AudioPreviewPlayer.shared
    @Environment(\.sliveLayout) private var layout
    @Environment(\.sliveScrollTo) private var scrollTo
    /// Navigates to the Models page (key entry lives there).
    var openModels: () -> Void = {}

    // Ground-truth transcription state.
    @State private var fetching: Set<String> = []      // sample ids in flight
    @State private var bulkRunning = false
    @State private var bulkDone = 0
    @State private var bulkTotal = 0
    @State private var gtError: String?
    @State private var confirmClear = false
    @State private var samplePage = 0
    @State private var editingSampleID: String?
    @State private var shouldBeDraft = ""
    /// Sample ids a bulk run didn't reach (it stops on the first error) — lets
    /// "Run left" resume exactly where it stopped instead of redoing the rest.
    @State private var remaining: [String] = []

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
        .onAppear { store.loadSamplesIfNeeded() }   // lazy index parse
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

    /// Providers whose models accept audio input (Anthropic's API doesn't).
    /// Local qualifies via audio-capable downloads (e.g. Gemma 3n); Whisper is
    /// the fully on-device judge — dictate on Tiny, ground-truth with Accurate.
    private let audioProviders: [AssistantProvider] = [.gemini, .openai, .openaiCompatible, .local, .whisper]

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

    private var groundTruthCard: some View {
        SettingsCard("GROUND TRUTH", trailing: {
            // Key presence at a glance; tap to manage keys (or, for Local,
            // downloaded models) in Models.
            Button(action: openModels) {
                if settings.groundTruthProvider.isLocal || settings.groundTruthProvider == .whisper {
                    OnDevicePill()
                } else {
                    KeyStatusPill(hasKey: providers.hasKey(settings.groundTruthProvider))
                }
            }
            .buttonStyle(.plain)
            .help(settings.groundTruthProvider == .whisper
                  ? "Runs fully on this Mac — no key"
                  : settings.groundTruthProvider.isLocal
                  ? "Models are downloaded in Models" : "Keys are managed in Models")
        }) {
            Text(settings.groundTruthProvider == .whisper
                 ? "A bigger Whisper re-judges your audio on-device — dictate on Tiny, ground-truth with Accurate. No cloud, no key."
                 : "A model with ears re-transcribes your audio into the Should-be column — the answer key Slive learns from.")
                .sliveCaption()

            HStack(spacing: 10) {
                Picker("", selection: $settings.groundTruthProvider) {
                    ForEach(audioProviders) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
                .onChange(of: settings.groundTruthProvider) { _, p in
                    settings.groundTruthModel = defaultAudioModel(p)
                    // Picking Local is explicit intent — list what's
                    // downloaded right away.
                    if p.isLocal && providers.models(for: p).isEmpty {
                        Task { await providers.fetchModels(for: .local) }
                    }
                }
                if settings.groundTruthProvider == .whisper { Spacer(minLength: 0) }
            }

            if settings.groundTruthProvider == .whisper {
                // The SAME picker + download linkage as the dictation model
                // card — status dot, download button, progress, all of it.
                ModelPickerRows(model: $settings.groundTruthModel)
            }

            if settings.groundTruthProvider != .whisper {
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

            HStack(spacing: 10) {
                Button {
                    bulkTranscribe()
                } label: {
                    Label(bulkRunning ? "Transcribing…" : "Transcribe missing (\(missingCount))",
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(SliveTheme.accent)
                .controlSize(.small)
                .disabled(bulkRunning || missingCount == 0)

                // Re-run every recording with the currently selected model —
                // replaces existing Should-be values (e.g. after switching to
                // a better model).
                Button {
                    bulkTranscribe(includeExisting: true)
                } label: {
                    Label("Run all (\(audioSampleCount))", systemImage: "arrow.triangle.2.circlepath")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(bulkRunning || audioSampleCount == 0)
                .help("Re-transcribe every recording with \(settings.groundTruthModel), replacing existing ground truth")

                // Appears only after a run stopped early — resumes the untouched
                // tail, which "Transcribe missing" can't reach once a Run-all has
                // already given those samples an (old) value.
                if !bulkRunning, !leftoverIDs.isEmpty {
                    Button {
                        runRemaining()
                    } label: {
                        Label("Run left (\(leftoverIDs.count))", systemImage: "arrow.uturn.left")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Resume where the last run stopped — only the \(leftoverIDs.count) it didn't reach")
                }

                // Ground truths that disagree with the output by more than
                // half are usually failures, not corrections — surface the
                // count and jump to the first so they get eyes.
                if !bulkRunning, !wayOffIDs.isEmpty {
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

                if bulkRunning {
                    ProgressView(value: Double(bulkDone), total: Double(max(bulkTotal, 1)))
                        .frame(width: 80)
                    Text("\(bulkDone)/\(bulkTotal)")
                        .font(SliveTheme.mono(11))
                        .foregroundStyle(.white.opacity(0.55))
                } else if missingCount == 0 && hasAudioSamples {
                    Label("All caught up", systemImage: "checkmark.seal.fill")
                        .font(SliveTheme.font(11, .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
            }

            if let err = gtError ?? providers.fetchError(for: settings.groundTruthProvider) {
                Text(err)
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Proof the audio is real BEFORE anything is sent: open the file as
    /// audio and count its frames. An empty or truncated WAV produces
    /// exactly the "model says there is no audio" failure — so it fails
    /// here, loudly, instead of confusing a provider.
    private func validatedAudioSeconds(_ url: URL) throws -> Double {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw GroundTruthClient.GroundTruthError.server(
                "This recording can't be opened as audio — the file is broken. Delete the row.")
        }
        let seconds = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        guard seconds >= 0.3 else {
            throw GroundTruthClient.GroundTruthError.server(String(
                format: "This recording holds only %.2fs of audio — nothing to transcribe. Delete the row.",
                seconds))
        }
        return seconds
    }

    /// One transcription, routed by provider: Whisper runs entirely in-app on
    /// the WhisperKit registry (no backend, no key); everything else goes
    /// through the backend proxy.
    private func groundTruthText(url: URL, provider: AssistantProvider,
                                 model: String) async throws -> String {
        _ = try validatedAudioSeconds(url)
        if provider == .whisper {
            guard let text = await TranscriptionModel.shared.transcribe(url, model: model),
                  !text.isEmpty else {
                throw GroundTruthClient.GroundTruthError.server(
                    "Whisper \(model) isn't ready — download it above, or the clip was silent.")
            }
            return text
        }
        return try await GroundTruthClient().transcribe(
            audioURL: url, provider: provider, model: model,
            apiKey: providers.apiKey(for: provider),
            baseURL: providers.baseURL(for: provider))
    }

    /// Fetch ground truth for one sample.
    private func fetchGroundTruth(_ sample: EditSample) {
        guard let url = store.audioURL(sample), !fetching.contains(sample.id) else { return }
        fetching.insert(sample.id)
        gtError = nil
        let provider = settings.groundTruthProvider
        let model = settings.groundTruthModel
        Task { @MainActor in
            defer { fetching.remove(sample.id) }
            do {
                let text = try await groundTruthText(url: url, provider: provider, model: model)
                store.setLLMTranscript(id: sample.id, text: text, model: model)
            } catch {
                gtError = error.localizedDescription
            }
        }
    }

    /// Sample ids a stopped run left behind that still exist and have audio.
    /// (Deletions since the stop drop out.)
    private var leftoverIDs: [String] {
        let present = Set(store.samples.filter { store.audioURL($0) != nil }.map(\.id))
        return remaining.filter { present.contains($0) }
    }

    /// Transcribe every sample that has audio but no ground truth yet. With
    /// `includeExisting`, re-run every recording and replace its Should-be
    /// value — the way to upgrade all ground truth after switching models.
    private func bulkTranscribe(includeExisting: Bool = false) {
        let todo = store.samples.filter {
            store.audioURL($0) != nil && (includeExisting || $0.llmTranscript == nil)
        }
        runBulk(todo)
    }

    /// Resume a run that stopped: only the samples it never reached, with the
    /// currently selected model (so fixing the model then resuming works).
    private func runRemaining() {
        let ids = Set(leftoverIDs)
        runBulk(store.samples.filter { ids.contains($0.id) && store.audioURL($0) != nil })
    }

    /// The shared sequential loop. Sequential on purpose: provider rate limits,
    /// and one error stops the run instead of failing 30 requests at once —
    /// remembering the untouched tail so "Run left" can pick it up.
    private func runBulk(_ todo: [EditSample]) {
        guard !bulkRunning, !todo.isEmpty else { return }
        bulkRunning = true
        gtError = nil
        remaining = []
        let provider = settings.groundTruthProvider
        let model = settings.groundTruthModel
        bulkTotal = todo.count
        bulkDone = 0
        Task { @MainActor in
            defer { bulkRunning = false }
            for (index, sample) in todo.enumerated() {
                guard let url = store.audioURL(sample) else { continue }
                do {
                    let text = try await groundTruthText(url: url, provider: provider, model: model)
                    store.setLLMTranscript(id: sample.id, text: text, model: model)
                    bulkDone += 1
                } catch {
                    // Remember this sample and every one after it.
                    remaining = todo[index...].map(\.id)
                    gtError = "\(error.localizedDescription) — stopped, \(remaining.count) left"
                    return
                }
            }
        }
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
                samplePage = max(0, samplePage - 1)
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
                samplePage = min(pageCount - 1, samplePage + 1)
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
        } else if fetching.contains(sample.id) {
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
                if sample.finalText.isEmpty, sample.llmTranscript != nil {
                    // Redo the model label. A human edit, once present, remains
                    // authoritative and is never silently replaced.
                    Button { fetchGroundTruth(sample) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("Re-transcribe with \(settings.groundTruthModel)")
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
                Button { fetchGroundTruth(sample) } label: {
                    Label("Get", systemImage: "wand.and.stars")
                        .font(SliveTheme.font(11, .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Transcribe with \(settings.groundTruthModel)")
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
