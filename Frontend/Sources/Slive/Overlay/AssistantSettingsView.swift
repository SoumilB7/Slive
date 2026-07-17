import AppKit
import SwiftUI

/// The Assistant page: one top-down setup flow — shortcut, provider/keys,
/// prompt. Renders just its stack of cards — the host supplies the scroll
/// container, padding, and width.
struct AssistantSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var backend = BackendManager.shared

    @State private var apiKeyDraft: String = ""
    @State private var promptNames: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            if backend.status == .starting {
                startingBanner
            }
            shortcutCard
            providerCard
            promptCard
        }
        .onAppear {
            apiKeyDraft = settings.apiKey(for: settings.assistantConfig.provider)
            promptNames = PromptLibrary.available()
        }
    }

    /// Shown only while the local backend is spinning up (it starts lazily on
    /// the first ask or model fetch — offline beforehand is normal and silent).
    private var startingBanner: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Backend starting…")
                .font(SliveTheme.captionFont)
                .foregroundStyle(SliveTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05))
        )
    }

    // MARK: - Shortcut

    private var shortcutCard: some View {
        SettingsCard("SHORTCUT") {
            HotkeyRecorderView(
                target: .assistant,
                title: "Assistant shortcut",
                subtitle: "Hold to ask the LLM — e.g. fn + control. Its answer appears in the floating box."
            )
            CardDivider()
            if settings.assistantHotkey == nil {
                Label("Assistant mode is off until you record a shortcut.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.9))
            } else {
                StepsRibbon(steps: [
                    .init(icon: "hand.point.up.left.fill", text: "Hold",
                          key: settings.assistantHotkey?.label),
                    .init(icon: "waveform", text: "Speak"),
                    .init(icon: "sparkles", text: "Answer appears"),
                ])
            }
        }
    }

    // MARK: - Provider

    private var providerCard: some View {
        SettingsCard("PROVIDER") {
            // Zone A — provider + key presence at a glance.
            HStack(spacing: 10) {
                Text("Provider")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Spacer()
                KeyStatusPill(hasKey: !apiKeyDraft.isEmpty)
                Picker("", selection: providerBinding) {
                    ForEach(AssistantProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
            }

            // Zone B — one model field: type any id, or pick a fetched one.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Model")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                    Spacer()
                    if loadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { fetchModels() } label: {
                            Label("Fetch live models", systemImage: "arrow.clockwise")
                                .font(SliveTheme.font(11, .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SliveTheme.accent)
                    }
                }
                modelField
                if let err = modelsError {
                    Text(err)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(currentFetched.isEmpty
                         ? "Fetch live models to pick from your provider, or type any id."
                         : "\(currentFetched.count) live models saved — refetch to update.")
                        .sliveCaption()
                }
            }

            // Zone C — secrets.
            if settings.assistantConfig.provider.needsBaseURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                    TextField("https://…/v1", text: $settings.assistantConfig.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("OpenRouter, Groq, Ollama, LM Studio — anything that speaks the OpenAI API.")
                        .sliveCaption()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                SecureField(settings.assistantConfig.provider.keyHint, text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: apiKeyDraft) { _, new in
                        settings.setAPIKey(new, for: settings.assistantConfig.provider)
                    }
                Text("Kept in your macOS Keychain — never on disk.")
                    .sliveCaption()
            }

            CardDivider()

            ToggleRow(
                title: "Attach a full-screen screenshot",
                caption: "Sends a screenshot with every question — macOS asks for Screen Recording once.",
                isOn: $settings.assistantConfig.attachScreenshot
            )
        }
    }

    /// The single model control: a mono text field showing exactly the id that
    /// will be sent, with a trailing menu chip listing fetched models.
    private var modelField: some View {
        TextField(settings.assistantConfig.provider.defaultModel, text: selectedModel)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .overlay(alignment: .trailing) {
                if !currentFetched.isEmpty {
                    Menu {
                        ForEach(currentFetched, id: \.self) { m in
                            Button(m) { selectedModel.wrappedValue = m }
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
    }

    /// Reloads the key draft when the provider changes. The stored model list is
    /// per-provider, so switching just shows that provider's remembered list.
    private var providerBinding: Binding<AssistantProvider> {
        Binding(
            get: { settings.assistantConfig.provider },
            set: { newValue in
                settings.assistantConfig.provider = newValue
                apiKeyDraft = settings.apiKey(for: newValue)
                modelsError = nil
            }
        )
    }

    /// Models remembered for the current provider (persisted; only refreshed
    /// when you tap "Fetch live models").
    private var currentFetched: [String] {
        settings.assistantConfig.fetchedModels[settings.assistantConfig.provider.rawValue] ?? []
    }

    /// The effective model id (override, else the provider default). Setting it
    /// stores an override.
    private var selectedModel: Binding<String> {
        Binding(
            get: { settings.assistantConfig.model(for: settings.assistantConfig.provider) },
            set: { settings.assistantConfig.setModel($0, for: settings.assistantConfig.provider) }
        )
    }

    private func fetchModels() {
        loadingModels = true
        modelsError = nil
        let config = settings.assistantConfig
        let key = settings.apiKey(for: config.provider)
        Task {
            // The backend serves /models and starts lazily — make sure it's up
            // so a fetch never fails just because nothing asked it to spawn yet.
            let healthy = await BackendManager.shared.ensureHealthy()
            guard healthy else {
                await MainActor.run {
                    modelsError = "Couldn't start the local backend."
                    loadingModels = false
                }
                return
            }
            do {
                let models = try await AssistantClient().listModels(config: config, apiKey: key)
                await MainActor.run {
                    // Persist per provider — only updated on an explicit fetch.
                    settings.assistantConfig.fetchedModels[config.provider.rawValue] = models
                    loadingModels = false
                    if models.isEmpty { modelsError = "No models returned for this provider." }
                }
            } catch {
                await MainActor.run {
                    modelsError = String(describing: error)
                    loadingModels = false
                }
            }
        }
    }

    // MARK: - Prompt

    private var promptCard: some View {
        SettingsCard("PROMPT", trailing: {
            Button("Open folder") { openPromptsFolder() }
                .buttonStyle(.plain)
                .font(SliveTheme.font(11, .semibold))
                .foregroundStyle(SliveTheme.accent)
        }) {
            HStack {
                Text("System prompt")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Spacer()
                Picker("", selection: $settings.assistantConfig.promptName) {
                    Text("Custom…").tag("")
                    ForEach(promptNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
            }

            if settings.assistantConfig.promptName.isEmpty {
                TextEditor(text: $settings.assistantConfig.systemPrompt)
                    .font(SliveTheme.font(12))
                    .foregroundStyle(.white.opacity(0.9))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 150)
                    .innerWell()
            } else {
                Label("prompts/\(settings.assistantConfig.promptName)",
                      systemImage: "doc.text")
                    .font(SliveTheme.font(12, .semibold))
                    .foregroundStyle(SliveTheme.textMid)
                // Long prompt files scroll inside a capped preview instead of
                // blowing the card open.
                ScrollView {
                    Text(PromptLibrary.contents(named: settings.assistantConfig.promptName)
                         ?? "(couldn't read this file)")
                        .font(SliveTheme.font(12, .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .innerWell()
                Text("Edit the file — changes apply on the next ask.")
                    .sliveCaption()
            }
        }
    }

    private func openPromptsFolder() {
        guard let dir = PromptLibrary.directory else { return }
        NSWorkspace.shared.open(dir)
    }
}
