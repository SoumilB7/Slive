import AppKit
import SwiftUI

/// The Models page: every provider Slive can think with, configured in ONE
/// place — API keys (Keychain), the OpenAI-compatible base URL, live model
/// lists, and the upcoming Local (Hugging Face) provider. Assistant and
/// Training only pick provider + model; their keys resolve here.
struct ModelsSettingsView: View {
    @ObservedObject var settings: Settings
    @Environment(\.sliveLayout) private var layout

    var body: some View {
        VStack(spacing: SliveTheme.cardGap) {
            Text("Keys are kept in your macOS Keychain — never on disk. Every page that picks a model (Assistant, Training) reads from here.")
                .sliveCaption()
                .frame(maxWidth: .infinity, alignment: .leading)

            if layout == .wide {
                HStack(alignment: .top, spacing: SliveTheme.gridGap) {
                    VStack(spacing: SliveTheme.cardGap) {
                        ProviderCard(provider: .anthropic)
                        ProviderCard(provider: .gemini)
                        LocalProviderCard()
                    }
                    VStack(spacing: SliveTheme.cardGap) {
                        ProviderCard(provider: .openai)
                        ProviderCard(provider: .openaiCompatible)
                    }
                }
            } else {
                ProviderCard(provider: .anthropic)
                ProviderCard(provider: .openai)
                ProviderCard(provider: .gemini)
                ProviderCard(provider: .openaiCompatible)
                LocalProviderCard()
            }
        }
    }
}

// MARK: - One cloud provider

private struct ProviderCard: View {
    let provider: AssistantProvider
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var providers = ProviderStore.shared

    @State private var keyDraft = ""

    var body: some View {
        SettingsCard(provider.displayName.uppercased(), trailing: {
            KeyStatusPill(hasKey: !keyDraft.isEmpty)
        }) {
            if provider.needsBaseURL {
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
                SecureField(provider.keyHint, text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: keyDraft) { _, new in
                        providers.setAPIKey(new, for: provider)
                    }
            }

            CardDivider()

            HStack(spacing: 10) {
                if providers.isFetching(provider) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await providers.fetchModels(for: provider) }
                    } label: {
                        Label("Fetch live models", systemImage: "arrow.clockwise")
                            .font(SliveTheme.font(11, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SliveTheme.accent)
                }
                if let err = providers.fetchError(for: provider) {
                    Text(err)
                        .font(SliveTheme.captionFont)
                        .foregroundStyle(.orange.opacity(0.9))
                        .lineLimit(2)
                } else {
                    Text(providers.models(for: provider).isEmpty
                         ? "Fills the model picker everywhere."
                         : "\(providers.models(for: provider).count) models saved.")
                        .sliveCaption()
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { keyDraft = providers.apiKey(for: provider) }
    }
}

// MARK: - Local (Hugging Face) — phase 1

private struct LocalProviderCard: View {
    @ObservedObject private var providers = ProviderStore.shared
    @State private var tokenDraft = ""

    var body: some View {
        SettingsCard("LOCAL (HUGGING FACE)", trailing: {
            KeyStatusPill(hasKey: !tokenDraft.isEmpty)
        }) {
            Text("Runs models on this Mac, downloaded from Hugging Face. Add your access token now — model download and on-device inference are the next milestone; once live, Local joins the provider pickers in Assistant and Training.")
                .sliveCaption()
            VStack(alignment: .leading, spacing: 6) {
                Text("Access token")
                    .font(SliveTheme.rowFont)
                    .foregroundStyle(SliveTheme.textPrimary)
                SecureField("hf_…  (huggingface.co/settings/tokens)", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: tokenDraft) { _, new in
                        providers.setHuggingFaceToken(new)
                    }
            }
        }
        .onAppear { tokenDraft = providers.huggingFaceToken }
    }
}
