import AppKit
import SwiftUI

/// The "Assistant" top-level section: configure the LLM hotkey, provider/keys,
/// and the prompt that steers its answers. Its own sub-tabs, separate from the
/// dictation settings.
struct AssistantSettingsView: View {
    @ObservedObject var settings: Settings
    var accent: Color

    private enum ATab: String, CaseIterable, Identifiable {
        case shortcut = "Shortcut"
        case provider = "Provider"
        case prompt = "Prompt"
        var id: String { rawValue }
    }

    @State private var atab: ATab = .shortcut
    @State private var apiKeyDraft: String = ""
    @State private var promptNames: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $atab) {
                ForEach(ATab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 22) {
                    switch atab {
                    case .shortcut: shortcutSection
                    case .provider: providerSection
                    case .prompt:   promptSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            apiKeyDraft = settings.apiKey(for: settings.assistantConfig.provider)
            promptNames = PromptLibrary.available()
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                step(icon: "hand.point.up.left.fill", title: "Hold", detail: assistantLabel)
                arrow
                step(icon: "waveform", title: "Ask", detail: "Speak")
                arrow
                step(icon: "sparkles", title: "Answer", detail: "In the box")
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("ASSISTANT SHORTCUT")
                HotkeyRecorderView(
                    accent: accent,
                    target: .assistant,
                    title: "Assistant shortcut",
                    subtitle: "Hold to ask the LLM — e.g. fn + control. Its answer appears in the floating box."
                )
                if settings.assistantHotkey == nil {
                    Text("Assistant mode is off until you record a shortcut.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange.opacity(0.9))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(card)
        }
    }

    private var assistantLabel: String { settings.assistantHotkey?.label ?? "Not set" }

    // MARK: - Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("PROVIDER")

            Picker("Provider", selection: providerBinding) {
                ForEach(AssistantProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            .tint(accent)

            modelPicker

            if settings.assistantConfig.provider.needsBaseURL {
                field(label: "Base URL", hint: "e.g. https://openrouter.ai/api/v1 or http://localhost:11434/v1",
                      text: $settings.assistantConfig.baseURL,
                      placeholder: "https://…/v1")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                SecureField(settings.assistantConfig.provider.keyHint, text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: apiKeyDraft) { _, new in
                        settings.setAPIKey(new, for: settings.assistantConfig.provider)
                    }
                Text("Stored securely in your macOS Keychain — never written to disk in plain text.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Divider().overlay(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $settings.assistantConfig.attachScreenshot) {
                    Text("Attach a full-screen screenshot")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .toggleStyle(.switch)
                .tint(accent)
                Text("When on, a screenshot of your screen is sent with every assistant question. Needs Screen Recording permission (macOS asks the first time).")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
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

    /// Models remembered for the current provider (persisted; only refreshed when
    /// you tap "Fetch live models").
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

    /// Fetched models, guaranteeing the currently-selected one is present so the
    /// Picker always has a valid tag.
    private var modelOptions: [String] {
        var opts = currentFetched
        let current = settings.assistantConfig.model(for: settings.assistantConfig.provider)
        if !current.isEmpty && !opts.contains(current) { opts.insert(current, at: 0) }
        return opts
    }

    @ViewBuilder private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                if loadingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Button { fetchModels() } label: {
                        Label("Fetch live models", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                }
            }

            if !modelOptions.isEmpty {
                Picker("", selection: selectedModel) {
                    ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accent)
            }

            // Always allow a manual id (custom deployments, unreleased models).
            TextField(settings.assistantConfig.provider.defaultModel, text: selectedModel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            if let err = modelsError {
                Text(err)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(currentFetched.isEmpty
                     ? "Tap “Fetch live models” to load the list from your provider, or type an id."
                     : "\(currentFetched.count) live models saved — pick one above, refetch to update, or type any id.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func fetchModels() {
        loadingModels = true
        modelsError = nil
        let config = settings.assistantConfig
        let key = settings.apiKey(for: config.provider)
        Task {
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

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("PROMPT")
                Spacer()
                Button("Open folder") { openPromptsFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            }

            Picker("Prompt", selection: $settings.assistantConfig.promptName) {
                Text("Custom…").tag("")
                ForEach(promptNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .tint(accent)

            if settings.assistantConfig.promptName.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom system prompt")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    promptEditor($settings.assistantConfig.systemPrompt)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From prompts/\(settings.assistantConfig.promptName)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(PromptLibrary.contents(named: settings.assistantConfig.promptName)
                         ?? "(couldn't read this file)")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.05))
                        )
                    Text("Edit this file in the prompts folder — changes apply on the next request.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func promptEditor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 120, maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 0.8)
                    )
            )
    }

    private func openPromptsFolder() {
        guard let dir = PromptLibrary.directory else { return }
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Shared bits

    private func field(label: String, hint: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text(hint)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(height: 24)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(card)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.25))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .tracking(1.2)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
            )
    }
}
