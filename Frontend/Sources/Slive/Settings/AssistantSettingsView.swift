import AppKit
import SwiftUI

/// The Assistant page: one top-down setup flow — shortcut, brain (provider +
/// model only; credentials live in the Models page), prompt. Renders just its
/// stack of cards — the host supplies the scroll container, padding, and width.
struct AssistantSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var backend = BackendManager.shared
    @ObservedObject private var providers = ProviderStore.shared
    /// Navigates to the Models page (key entry lives there).
    var openModels: () -> Void = {}

    @State private var promptNames: [String] = []
    @ObservedObject private var promptLog = AssistantPromptLog.shared
    @State private var sentPromptExpanded = false

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
            promptNames = PromptLibrary.available()
        }
    }

    /// Shown only while the local backend is spinning up (it starts lazily on
    /// the first ask or model fetch — offline beforehand is normal and silent).
    private var startingBanner: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Starting…")
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
            HotkeyRecorderView(target: .assistant, title: "Hold to ask")
            if settings.assistantHotkey == nil {
                Label("No shortcut set.", systemImage: "exclamationmark.triangle.fill")
                    .font(SliveTheme.captionFont)
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
    }

    // MARK: - Provider

    private var providerCard: some View {
        SettingsCard("PROVIDER", trailing: {
            // Key presence at a glance; tap to manage keys (or, for Local,
            // downloaded models) in Models.
            Button(action: openModels) {
                if settings.assistantConfig.provider.isLocal {
                    OnDevicePill()
                } else {
                    KeyStatusPill(hasKey: providers.hasKey(settings.assistantConfig.provider))
                }
            }
            .buttonStyle(.plain)
            .help(settings.assistantConfig.provider.isLocal ? "Manage models" : "Manage keys")
        }) {
            HStack(spacing: 10) {
                Text("Provider")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                Spacer()
                Picker("", selection: providerBinding) {
                    ForEach(AssistantProvider.assistantChoices) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(SliveTheme.accent)
                .fixedSize()
            }

            // One model field: type any id, or pick a fetched one.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Model")
                        .font(SliveTheme.rowFont)
                        .foregroundStyle(SliveTheme.textPrimary)
                    Spacer()
                    if providers.isFetching(settings.assistantConfig.provider) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await providers.fetchModels(for: settings.assistantConfig.provider) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(SliveTheme.font(11, .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SliveTheme.accent)
                    }
                }
                modelField
                if let err = providers.fetchError(for: settings.assistantConfig.provider) {
                    Text(err)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                } else if settings.assistantConfig.provider.isLocal {
                    if currentFetched.isEmpty {
                        HStack(spacing: 8) {
                            Text("No local models.").sliveCaption()
                            Button("Get models →", action: openModels)
                                .buttonStyle(.plain)
                                .font(SliveTheme.font(11, .semibold))
                                .foregroundStyle(SliveTheme.accent)
                        }
                    } else {
                        Text("\(currentFetched.count) downloaded").sliveCaption()
                    }
                } else if !currentFetched.isEmpty {
                    Text("\(currentFetched.count) models").sliveCaption()
                }
            }

            CardDivider()

            ToggleRow(title: "Include screenshot", isOn: $settings.assistantConfig.attachScreenshot)
                .help("Sends your screen with each question")
        }
    }

    /// The single model control: a mono text field showing exactly the id that
    /// will be sent, with a trailing menu chip listing fetched models.
    private var modelField: some View {
        TextField(settings.assistantConfig.provider.isLocal
                  ? "Model" : settings.assistantConfig.provider.defaultModel,
                  text: selectedModel)
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

    /// The stored model list is per-provider, so switching just shows that
    /// provider's remembered list (and its own key pill / fetch state).
    private var providerBinding: Binding<AssistantProvider> {
        Binding(
            get: { settings.assistantConfig.provider },
            set: {
                settings.assistantConfig.provider = $0
                // Picking Local is explicit intent — list what's downloaded
                // right away instead of waiting for a manual refresh.
                if $0.isLocal && currentFetched.isEmpty {
                    Task { await ProviderStore.shared.fetchModels(for: .local) }
                }
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
                         ?? "Can't read file")
                        .font(SliveTheme.font(12, .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .innerWell()
            }

            // What actually went in on the LAST ask — the resolved system
            // prompt as sent, not the file preview above (they can differ if
            // the file changed since, or a Custom prompt is live).
            if settings.verboseLogging, let sent = promptLog.lastSystemPrompt {
                CardDivider()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { sentPromptExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(sentPromptExpanded ? 90 : 0))
                        Text("Last prompt sent")
                            .font(SliveTheme.font(11, .semibold))
                        if let meta = promptLog.lastMeta {
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
                if sentPromptExpanded {
                    ScrollView {
                        Text(sent)
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

    private func openPromptsFolder() {
        guard let dir = PromptLibrary.directory else { return }
        NSWorkspace.shared.open(dir)
    }
}
