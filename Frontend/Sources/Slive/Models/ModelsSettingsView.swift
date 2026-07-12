import AppKit
import SwiftUI

/// The Models page — where you connect the AI providers Slive can think with.
///
/// Redesigned as a **connections list**, not a wall of forms: add a key once to
/// any provider and every feature that picks a model (Assistant, Training) reads
/// it from here. Each provider is a compact, state-badged row you expand to
/// configure — so the page reads at a glance ("OpenAI is connected, the rest
/// aren't") instead of presenting five identical empty forms.
struct ModelsSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var providers = ProviderStore.shared
    @Environment(\.sliveLayout) private var layout

    /// Which rows are expanded (by provider rawValue / "huggingface").
    @State private var expanded: Set<String> = []
    @State private var seeded = false

    private let cloud: [AssistantProvider] = [.anthropic, .openai, .gemini, .openaiCompatible]

    private var connectedCount: Int { cloud.filter { providers.hasKey($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: SliveTheme.cardGap) {
            header

            VStack(alignment: .leading, spacing: 18) {
                group("CLOUD PROVIDERS") {
                    ForEach(cloud) { p in
                        ProviderRow(provider: p, expanded: binding(for: p.rawValue))
                    }
                }
                group("ON THIS MAC") {
                    LocalProviderRow(expanded: binding(for: "huggingface"))
                }
            }
        }
        .onAppear(perform: seedExpansion)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect an AI provider")
                .font(SliveTheme.font(17, .bold))
                .foregroundStyle(SliveTheme.textPrimary)
            Text("Add a key once here. The Assistant and Training then let you pick any of that provider's models — you never set it up twice.")
                .font(SliveTheme.font(12))
                .foregroundStyle(SliveTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SliveTheme.textTertiary)
                Text("Keys stay in your macOS Keychain — never written to disk.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textTertiary)
                Spacer(minLength: 12)
                connectedBadge
            }
            .padding(.top, 2)
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectedCount > 0 ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(connectedCount > 0
                 ? "\(connectedCount) connected"
                 : "None connected yet")
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(connectedCount > 0 ? .green : .orange.opacity(0.95))
        }
        .fixedSize()
    }

    // MARK: - Group

    @ViewBuilder private func group<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SliveTheme.font(10, .bold))
                .foregroundStyle(SliveTheme.textTertiary)
                .tracking(1.1)
                .padding(.leading, 2)
            VStack(spacing: 10) { content() }
        }
    }

    // MARK: - Expansion state

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    /// First run (nothing connected): open the first row so the user sees a key
    /// field immediately instead of five collapsed strangers. Otherwise start
    /// collapsed — the summaries say everything.
    private func seedExpansion() {
        guard !seeded else { return }
        seeded = true
        if connectedCount == 0 { expanded.insert(cloud[0].rawValue) }
    }
}

// MARK: - One cloud provider (expandable connection row)

private struct ProviderRow: View {
    let provider: AssistantProvider
    @Binding var expanded: Bool

    @ObservedObject private var providers = ProviderStore.shared
    @ObservedObject private var settings = Settings.shared
    @State private var keyDraft = ""

    private var connected: Bool { !keyDraft.isEmpty }
    private var modelCount: Int { providers.models(for: provider).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton
            if expanded {
                CardDivider().padding(.top, 12)
                detail.padding(.top, 12)
            }
        }
        .padding(SliveTheme.cardPad)
        .background(rowBackground)
        .onAppear { keyDraft = providers.apiKey(for: provider) }
    }

    // MARK: Collapsed header (always visible, taps to expand)

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                    Text(statusLine)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(connected ? SliveTheme.accent : SliveTheme.textSecondary)
                }
                Spacer(minLength: 8)
                if connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SliveTheme.accent)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(connected ? SliveTheme.accent.opacity(0.16) : .white.opacity(0.05))
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: Self.glyph[provider] ?? "cloud.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(connected ? SliveTheme.accent : SliveTheme.textSecondary)
            )
    }

    private var statusLine: String {
        guard connected else { return "Not connected — tap to add a key" }
        return modelCount > 0 ? "Connected · \(modelCount) models" : "Connected"
    }

    // MARK: Expanded detail

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if provider.needsBaseURL {
                labeledField("Base URL",
                             hint: "OpenRouter, Groq, Ollama, LM Studio — anything that speaks the OpenAI API.") {
                    TextField("https://…/v1", text: $settings.assistantConfig.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            labeledField("API key") {
                SecureField(provider.keyHint, text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: keyDraft) { _, new in
                        providers.setAPIKey(new, for: provider)
                    }
            }

            if !connected, let url = Self.signup[provider] {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Get a key")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(SliveTheme.font(11, .semibold))
                    .foregroundStyle(SliveTheme.accent)
                }
                .buttonStyle(.plain)
            }

            if connected {
                CardDivider()
                modelsRow
            }
        }
    }

    /// The optional model-list refresh — reframed from "Fetch live models /
    /// Fills the model picker everywhere" (jargon) to a plainly optional
    /// convenience, only shown once a key exists.
    private var modelsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if providers.isFetching(provider) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…")
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.textSecondary)
                } else {
                    Button {
                        Task { await providers.fetchModels(for: provider) }
                    } label: {
                        Label(modelCount > 0 ? "Refresh model list" : "Load model list",
                              systemImage: "arrow.clockwise")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(SliveTheme.accent)
                    if modelCount > 0 {
                        Text("\(modelCount) available")
                            .font(SliveTheme.captionFont)
                            .foregroundStyle(SliveTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let err = providers.fetchError(for: provider) {
                Text(err)
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Optional — lets you pick from the live list in Assistant & Training instead of typing a model id.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Chrome

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: SliveTheme.cardRadius, style: .continuous)
            .fill(SliveTheme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: SliveTheme.cardRadius, style: .continuous)
                    .strokeBorder(connected ? SliveTheme.accent.opacity(0.35) : SliveTheme.cardStroke,
                                  lineWidth: connected ? 1 : 0.8)
            )
    }

    @ViewBuilder private func labeledField<Content: View>(
        _ label: String, hint: String? = nil, @ViewBuilder _ field: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(SliveTheme.rowFont)
                .foregroundStyle(SliveTheme.textPrimary)
            field()
            if let hint {
                Text(hint).sliveCaption()
            }
        }
    }

    // MARK: Per-provider metadata (brand-free glyphs + where to get a key)

    private static let glyph: [AssistantProvider: String] = [
        .anthropic: "a.circle.fill",
        .openai: "o.circle.fill",
        .gemini: "g.circle.fill",
        .openaiCompatible: "chevron.left.forwardslash.chevron.right",
    ]
    private static let signup: [AssistantProvider: URL] = [
        .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!,
        .openai: URL(string: "https://platform.openai.com/api-keys")!,
        .gemini: URL(string: "https://aistudio.google.com/apikey")!,
    ]
}

// MARK: - Local (Hugging Face) — download into the standard cache + browse it

private struct LocalProviderRow: View {
    @Binding var expanded: Bool
    @ObservedObject private var providers = ProviderStore.shared

    @State private var tokenDraft = ""
    @State private var modelIDDraft = ""
    @State private var filter = ""

    private var downloading: String? { providers.localDownloading }

    /// Only real models are shown. Most HF cache entries are tiny config-only
    /// repos (tokenizers, adapters, other projects' leftovers) — the shared
    /// size floor keeps this to actual models without the noise.
    private var models: [LocalCachedModel] {
        providers.localModels.filter { $0.size_bytes >= LocalCachedModel.minPickableBytes }
    }
    private var hiddenSmallCount: Int {
        providers.localModels.count - models.count
    }
    private var filteredModels: [LocalCachedModel] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter { $0.repo_id.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                CardDivider().padding(.top, 12)
                detail.padding(.top, 12)
            }
        }
        .padding(SliveTheme.cardPad)
        .background(
            RoundedRectangle(cornerRadius: SliveTheme.cardRadius, style: .continuous)
                .fill(SliveTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: SliveTheme.cardRadius, style: .continuous)
                        .strokeBorder(SliveTheme.cardStroke, lineWidth: 0.8)
                )
        )
        .onAppear {
            tokenDraft = providers.huggingFaceToken
            if providers.localModels.isEmpty { Task { await providers.refreshLocalCache() } }
        }
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SliveTheme.textSecondary)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local (Hugging Face)")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                    Text(subtitle)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(SliveTheme.textSecondary)
                }
                Spacer(minLength: 8)
                if downloading != nil {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if let downloading { return "Downloading \(downloading)…" }
        let n = models.count
        return n > 0 ? "\(n) model\(n == 1 ? "" : "s") on this Mac" : "Download models to this Mac"
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Downloads land in your standard Hugging Face cache (shared with transformers / PyTorch) and run in the Python backend. Running downloaded models for the Assistant is the next milestone.")
                .sliveCaption()

            // Access token (saves as you type — the pill confirms it).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Access token (for gated / private repos)")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                    Spacer()
                    KeyStatusPill(hasKey: !tokenDraft.isEmpty)
                }
                SecureField("hf_…  (huggingface.co/settings/tokens)", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: tokenDraft) { _, new in providers.setHuggingFaceToken(new) }
                Text("Saved automatically to your Keychain — no button needed.")
                    .sliveCaption()
            }

            CardDivider()

            // Download by id.
            VStack(alignment: .leading, spacing: 6) {
                Text("Download a model")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                HStack(spacing: 8) {
                    TextField("owner/name  (e.g. google/gemma-3-4b-it)", text: $modelIDDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(startDownload)
                    if downloading != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Download", action: startDownload)
                            .buttonStyle(.borderedProminent)
                            .tint(SliveTheme.accent)
                            .controlSize(.small)
                            .disabled(modelIDDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let err = providers.localError {
                    Text(err)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(.orange.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CardDivider()

            cacheList
        }
    }

    // MARK: In your cache

    private var cacheList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("IN YOUR CACHE")
                    .font(SliveTheme.font(10, .bold))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .tracking(1.1)
                if providers.localLoading { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    Task { await providers.refreshLocalCache() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SliveTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Re-read the Hugging Face cache")
            }

            if models.isEmpty {
                Text(providers.localLoading ? "Reading cache…" : "No models downloaded yet.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textTertiary)
                    .padding(.vertical, 4)
            } else {
                if models.count > 8 {
                    TextField("Filter \(models.count) models…", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredModels) { model in
                            cacheRow(model)
                            Divider().overlay(.white.opacity(0.05))
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            if hiddenSmallCount > 0 {
                Text("\(hiddenSmallCount) small config-only repos under 50 MB hidden.")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textTertiary)
            }
        }
    }

    private func cacheRow(_ model: LocalCachedModel) -> some View {
        HStack(spacing: 10) {
            Text(model.repo_id)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SliveTheme.textMid)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(model.sizeText)
                .font(SliveTheme.mono(11))
                .foregroundStyle(SliveTheme.textSecondary)
                .fixedSize()
            Button {
                Task { await providers.deleteLocalModel(model.repo_id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Delete \(model.repo_id) from the cache")
        }
        .padding(.vertical, 7)
    }

    // MARK: Actions

    private func startDownload() {
        let id = modelIDDraft.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        Task {
            await providers.downloadLocalModel(id)
            if providers.localError == nil { modelIDDraft = "" }
        }
    }
}
