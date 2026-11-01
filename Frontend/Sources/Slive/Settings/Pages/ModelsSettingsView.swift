import AppKit
import SwiftUI

extension SettingsPageID {
    static let providers = SettingsPageID("providers")
}

extension SettingsPageSpec {
    static let providers = SettingsPageSpec(
        id: .providers, title: "Providers", icon: "key.fill", section: .lab,
        requires: \.providers,
        width: .list,
        status: { env in
            let n = ProviderCatalog.keyed.filter { env.providers.hasKey($0) }.count
            return SettingsPageStatus(text: n > 0 ? "\(n) connected" : "None connected",
                                      color: n > 0 ? SliveTheme.textSecondary : SliveTheme.warn)
        }
    ) { ctx in
        AnyView(ModelsSettingsView(settings: ctx.env.settings, providers: ctx.env.providers))
    }
}

/// The Models page — where you connect the AI providers Slive can think with.
///
/// Redesigned as a **connections list**, not a wall of forms: add a key once to
/// any provider and every feature that picks a model (Assistant, Training) reads
/// it from here. Each provider is a compact, state-badged row you expand to
/// configure — so the page reads at a glance ("OpenAI is connected, the rest
/// aren't") instead of presenting five identical empty forms.
struct ModelsSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var providers: ProviderStore
    @Environment(\.sliveLayout) private var layout

    /// Which rows are expanded (by provider rawValue / "huggingface").
    @State private var expanded: Set<String> = []
    @State private var seeded = false

    private let cloud = ProviderCatalog.keyed

    private var connectedCount: Int { cloud.filter { providers.hasKey($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: SliveTheme.cardGap) {
            VStack(alignment: .leading, spacing: 18) {
                group("CLOUD") {
                    ForEach(cloud) { p in
                        ProviderRow(provider: p, expanded: binding(for: p.rawValue),
                                    providers: providers, settings: settings)
                    }
                }
                .help("Keys are stored in your Keychain")
                group("ON THIS MAC") {
                    LocalProviderRow(expanded: binding(for: "huggingface"),
                                     providers: providers, settings: settings)
                }
            }
        }
        .onAppear(perform: seedExpansion)
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

    @ObservedObject var providers: ProviderStore
    @ObservedObject var settings: Settings
    @State private var keyDraft = ""

    /// What's actually in the keychain, not the draft: a failed write must
    /// not read as "Connected". (Re-renders on ProviderStore's keyEdition.)
    private var connected: Bool { providers.hasKey(provider) }
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
                        .font(SliveTheme.iconLarge)
                        .foregroundStyle(SliveTheme.accent)
                }
                Image(systemName: "chevron.down")
                    .font(SliveTheme.labelBoldFont)
                    .foregroundStyle(SliveTheme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
            .fill(connected ? SliveTheme.accentConnected : SliveTheme.cardFill)
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: provider.spec.icon)
                    .font(SliveTheme.iconFont)
                    .foregroundStyle(connected ? SliveTheme.accent : SliveTheme.textSecondary)
            )
    }

    private var statusLine: String {
        guard connected else { return "Not connected" }
        return modelCount > 0 ? "Connected · \(modelCount) models" : "Connected"
    }

    // MARK: Expanded detail

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if provider.needsBaseURL {
                labeledField("Base URL",
                             hint: "Any OpenAI-compatible endpoint.") {
                    TextField("https://…/v1", text: $settings.assistantConfig.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(SliveTheme.monoBody)
                }
            }

            labeledField("API key") {
                SecureField(provider.keyHint, text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(SliveTheme.monoBody)
                    .onChange(of: keyDraft) { _, new in
                        providers.setAPIKey(new, for: provider)
                    }
            }

            if !connected, let url = provider.spec.keyURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Get a key")
                        Image(systemName: "arrow.up.right")
                            .font(SliveTheme.badgeFont)
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
                        providers.requestModels(for: provider)
                    } label: {
                        Label("Refresh",
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
                    .foregroundStyle(SliveTheme.warnStrong)
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
}

// MARK: - Local (Hugging Face) — download into the standard cache + browse it

private struct LocalProviderRow: View {
    @Binding var expanded: Bool
    @ObservedObject var providers: ProviderStore
    /// For the runtime knobs (LocalInferenceControls observes it).
    let settings: Settings

    @State private var tokenDraft = ""
    @State private var modelIDDraft = ""
    @State private var filter = ""
    /// Repo id awaiting delete confirmation.
    @State private var pendingDelete: String?

    private var downloading: String? { providers.localDownloading }

    /// Only real models are shown. Most HF cache entries are tiny config-only
    /// repos (tokenizers, adapters, other projects' leftovers) — the shared
    /// size floor keeps this to actual models without the noise.
    private var models: [LocalCachedModel] {
        providers.localModels.filter { $0.size_bytes >= LocalCachedModel.minPickableBytes }
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
                RoundedRectangle(cornerRadius: SliveTheme.rowRadius, style: .continuous)
                    .fill(SliveTheme.cardFill)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "desktopcomputer")
                            .font(SliveTheme.iconFont)
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
                    .font(SliveTheme.labelBoldFont)
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
        return n > 0 ? "\(n) model\(n == 1 ? "" : "s")" : "No models"
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Access token (saves as you type — the pill confirms it).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Access token")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                        .help("For gated repos")
                    Spacer()
                    KeyStatusPill(hasKey: !providers.huggingFaceToken.isEmpty)
                }
                SecureField("hf_…", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(SliveTheme.monoBody)
                    .onChange(of: tokenDraft) { _, new in providers.setHuggingFaceToken(new) }
            }

            CardDivider()

            // Download by id.
            VStack(alignment: .leading, spacing: 6) {
                Text("Download")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                HStack(spacing: 8) {
                    TextField("owner/name", text: $modelIDDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(SliveTheme.monoBody)
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
                        .foregroundStyle(SliveTheme.warnStrong)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CardDivider()

            cacheList

            CardDivider()

            runtimeSection
        }
    }

    /// How downloaded models run — quantization + the memory ceiling. These are
    /// one global pair, configured here (not repeated in Assistant / Ground
    /// Truth, which only pick a provider and a model).
    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RUNTIME")
                .font(SliveTheme.font(10, .bold))
                .foregroundStyle(SliveTheme.textTertiary)
                .tracking(1.1)
            LocalInferenceControls(settings: settings)
        }
    }

    // MARK: In your cache

    private var cacheList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("DOWNLOADED")
                    .font(SliveTheme.font(10, .bold))
                    .foregroundStyle(SliveTheme.textTertiary)
                    .tracking(1.1)
                if providers.localLoading { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    Task { await providers.refreshLocalCache() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(SliveTheme.labelFont)
                        .foregroundStyle(SliveTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            if models.isEmpty {
                Text(providers.localLoading ? "Reading…" : "None yet")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(SliveTheme.textTertiary)
                    .padding(.vertical, 4)
            } else {
                if models.count > 8 {
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .font(SliveTheme.bodyFont)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredModels) { model in
                            cacheRow(model)
                            Divider().overlay(SliveTheme.hairlineFaint)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .confirmationDialog("Delete \(pendingDelete ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete { Task { await providers.deleteLocalModel(id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func cacheRow(_ model: LocalCachedModel) -> some View {
        HStack(spacing: 10) {
            Text(model.repo_id)
                .font(SliveTheme.monoBody)
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
                pendingDelete = model.repo_id
            } label: {
                Image(systemName: "trash")
                    .font(SliveTheme.labelFont)
                    .foregroundStyle(SliveTheme.textFaint)
            }
            .buttonStyle(.plain)
            .help("Delete")
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
