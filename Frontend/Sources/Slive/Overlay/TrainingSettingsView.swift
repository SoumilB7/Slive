import AppKit
import SwiftUI

/// The Training page: capture pipeline (CAPTURE), ground-truth transcription
/// (GROUND TRUTH), and the sample browser (DATA) — one scrolling flow, no
/// drill-in. Renders just its stack; the host supplies scroll and outer width
/// (which lets DATA grow past the form cap at wide sizes).
struct TrainingSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var store = TrainingStore.shared
    @ObservedObject private var player = AudioPreviewPlayer.shared
    @Environment(\.sliveLayout) private var layout

    // Ground-truth transcription state.
    @State private var fetching: Set<String> = []      // sample ids in flight
    @State private var bulkRunning = false
    @State private var bulkDone = 0
    @State private var bulkTotal = 0
    @State private var gtError: String?
    @State private var keyDraft: String = ""
    @State private var confirmClear = false

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
        .onDisappear { player.stop() }
    }

    // MARK: - Capture (saving + size cap, one pipeline → one card)

    private var captureCard: some View {
        SettingsCard("CAPTURE") {
            ToggleRow(
                title: "Save dictations (audio + transcript)",
                caption: "Saves after typing finishes — never adds latency.",
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
    private let audioProviders: [AssistantProvider] = [.gemini, .openai, .openaiCompatible]

    /// Default audio-capable model per provider.
    private func defaultAudioModel(_ p: AssistantProvider) -> String {
        switch p {
        case .gemini: return "gemini-2.5-flash"
        case .openai: return "gpt-4o-audio-preview"
        default: return ""
        }
    }

    private var missingCount: Int {
        store.samples.filter { $0.llmTranscript == nil && store.audioURL($0) != nil }.count
    }

    private var hasAudioSamples: Bool {
        store.samples.contains { store.audioURL($0) != nil }
    }

    private var groundTruthCard: some View {
        SettingsCard("GROUND TRUTH") {
            Text("A model that can hear re-transcribes your audio into the Should-be column — the supervision signal for fine-tuning.")
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
                    keyDraft = settings.apiKey(for: p)
                }

                TextField("model (audio-capable)", text: $settings.groundTruthModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API key")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                    Spacer()
                    KeyStatusPill(hasKey: !keyDraft.isEmpty)
                }
                SecureField(settings.groundTruthProvider.keyHint, text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: keyDraft) { _, new in
                        settings.setAPIKey(new, for: settings.groundTruthProvider)
                    }
                    .onAppear { keyDraft = settings.apiKey(for: settings.groundTruthProvider) }
            }

            if settings.groundTruthProvider.needsBaseURL {
                TextField("base URL (https://…/v1)", text: $settings.groundTruthBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
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

            if let gtError {
                Text(gtError)
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fetch ground truth for one sample.
    private func fetchGroundTruth(_ sample: EditSample) {
        guard let url = store.audioURL(sample), !fetching.contains(sample.id) else { return }
        fetching.insert(sample.id)
        gtError = nil
        let provider = settings.groundTruthProvider
        let model = settings.groundTruthModel
        let key = settings.apiKey(for: provider)
        let baseURL = settings.groundTruthBaseURL
        Task { @MainActor in
            defer { fetching.remove(sample.id) }
            do {
                let text = try await GroundTruthClient().transcribe(
                    audioURL: url, provider: provider, model: model,
                    apiKey: key, baseURL: baseURL)
                store.setLLMTranscript(id: sample.id, text: text, model: model)
            } catch {
                gtError = error.localizedDescription
            }
        }
    }

    /// Sequentially fetch every sample that has audio but no ground truth yet.
    /// Sequential on purpose: provider rate limits, and errors stop the run
    /// instead of failing 30 requests at once.
    private func bulkTranscribe() {
        guard !bulkRunning else { return }
        bulkRunning = true
        gtError = nil
        let provider = settings.groundTruthProvider
        let model = settings.groundTruthModel
        let key = settings.apiKey(for: provider)
        let baseURL = settings.groundTruthBaseURL
        let todo = store.samples.filter { $0.llmTranscript == nil && store.audioURL($0) != nil }
        bulkTotal = todo.count
        bulkDone = 0
        Task { @MainActor in
            defer { bulkRunning = false }
            for sample in todo {
                guard let url = store.audioURL(sample) else { continue }
                do {
                    let text = try await GroundTruthClient().transcribe(
                        audioURL: url, provider: provider, model: model,
                        apiKey: key, baseURL: baseURL)
                    store.setLLMTranscript(id: sample.id, text: text, model: model)
                    bulkDone += 1
                } catch {
                    gtError = "\(error.localizedDescription) — stopped (\(missingCount) left)"
                    return
                }
            }
        }
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
                    caption: "Turn on Capture above and dictate — each row is one recording, what Slive wrote, and what it should have been."
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    tableHeaderRow
                    Divider().overlay(.white.opacity(0.1))
                    // Newest first.
                    ForEach(Array(store.samples.reversed())) { sample in
                        dataRow(sample)
                        Divider().overlay(.white.opacity(0.06))
                    }
                }
            }
        }
        .confirmationDialog("Delete \(store.count) sample\(store.count == 1 ? "" : "s")?",
                            isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { store.clearAll() }
            Button("Cancel", role: .cancel) {}
        }
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
        let isActive = player.currentID == sample.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                // Audio column: play/pause toggles the shared player onto this row.
                Group {
                    if let url = store.audioURL(sample) {
                        Button { player.toggle(id: sample.id, url: url) } label: {
                            Image(systemName: isActive && player.isPlaying
                                    ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(SliveTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .help(isActive && player.isPlaying ? "Pause" : "Play")
                    } else {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
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

                Spacer(minLength: 0)
            }

            // Scrubber, only under the row that's loaded in the player.
            if isActive {
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
                .padding(.leading, 52)   // align under the text columns
            }
        }
        .padding(.vertical, 9)
        .background {
            // The "live row" marker — whichever sample is loaded in the player.
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .padding(.horizontal, -8)
            }
        }
    }

    /// SHOULD BE cell states: word-diffed LLM transcript → legacy final text →
    /// spinner → "Get" wand → dash.
    @ViewBuilder private func shouldBeCell(_ sample: EditSample) -> some View {
        if let llm = sample.llmTranscript {
            if let diffed = TranscriptDiff.attributed(
                output: sample.transcript, truth: llm,
                base: .white.opacity(0.75), changed: .orange.opacity(0.95)) {
                Text(diffed).textSelection(.enabled)
            } else {
                // Very long sample — whole-string fallback.
                Text(llm)
                    .foregroundStyle(llm == sample.transcript
                                     ? .white.opacity(0.75) : .orange.opacity(0.95))
                    .textSelection(.enabled)
            }
        } else if !sample.finalText.isEmpty {
            Text(sample.finalText)
                .foregroundStyle(sample.edited ? .orange.opacity(0.95) : .white.opacity(0.75))
                .textSelection(.enabled)
        } else if fetching.contains(sample.id) {
            ProgressView().controlSize(.small)
        } else if store.audioURL(sample) != nil {
            Button { fetchGroundTruth(sample) } label: {
                Label("Get", systemImage: "wand.and.stars")
                    .font(SliveTheme.font(11, .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Transcribe with \(settings.groundTruthModel)")
        } else {
            Text("—").foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Shared

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
