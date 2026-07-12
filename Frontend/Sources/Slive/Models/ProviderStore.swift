import Foundation
import SwiftUI

/// The provider/model configuration module — one owner for everything about
/// "which AI can Slive talk to": credentials (Keychain), the OpenAI-compatible
/// base URL, live model lists, and the (upcoming) Local / Hugging Face
/// provider's token. Surfaces that USE a model — Assistant, Training — only
/// pick a provider and a model id; everything secret or provider-global is
/// entered once in the Models page and read through this store.
@MainActor
final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()

    private let settings = Settings.shared

    /// Bumped on any credential change so key pills refresh wherever they live.
    @Published private(set) var keyEdition = 0
    /// Providers (rawValue) with a live model-list fetch in flight.
    @Published private(set) var fetching: Set<String> = []
    /// Last fetch error per provider (rawValue). Cleared on the next fetch.
    @Published private(set) var fetchErrors: [String: String] = [:]

    private init() {
        migrateGroundTruthBaseURLIfNeeded()
    }

    // MARK: - Credentials (Keychain-backed via Settings)

    func apiKey(for provider: AssistantProvider) -> String {
        settings.apiKey(for: provider)
    }

    func setAPIKey(_ value: String, for provider: AssistantProvider) {
        settings.setAPIKey(value, for: provider)
        keyEdition += 1
    }

    func hasKey(_ provider: AssistantProvider) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    // MARK: - Local (Hugging Face) — phase 1: the token slot

    /// Keychain account for the Hugging Face access token used by the upcoming
    /// Local provider (downloads models to run on this Mac).
    static let hfAccount = "provider.huggingface"

    var huggingFaceToken: String {
        KeychainStore.get(Self.hfAccount) ?? ""
    }

    func setHuggingFaceToken(_ value: String) {
        KeychainStore.set(value.trimmingCharacters(in: .whitespacesAndNewlines),
                          for: Self.hfAccount)
        keyEdition += 1
    }

    // MARK: - Provider-global config

    /// The one base URL a provider needs (OpenAI-compatible only). Ground truth
    /// and assistant share it — it's provider config, not per-feature config.
    func baseURL(for provider: AssistantProvider) -> String {
        provider.needsBaseURL ? settings.assistantConfig.baseURL : ""
    }

    /// Live model list remembered for a provider (fetched explicitly).
    func models(for provider: AssistantProvider) -> [String] {
        settings.assistantConfig.fetchedModels[provider.rawValue] ?? []
    }

    func isFetching(_ provider: AssistantProvider) -> Bool {
        fetching.contains(provider.rawValue)
    }

    func fetchError(for provider: AssistantProvider) -> String? {
        fetchErrors[provider.rawValue]
    }

    /// Fetch the provider's live model list through the local backend and
    /// remember it (shared by every surface that picks models). Starts the
    /// lazy backend if needed.
    func fetchModels(for provider: AssistantProvider) async {
        let raw = provider.rawValue
        guard !fetching.contains(raw) else { return }
        fetching.insert(raw)
        fetchErrors[raw] = nil
        defer { fetching.remove(raw) }

        guard await BackendManager.shared.ensureHealthy() else {
            fetchErrors[raw] = "Couldn't start the local backend."
            return
        }
        var config = settings.assistantConfig
        config.provider = provider
        config.baseURL = baseURL(for: provider)
        do {
            let models = try await AssistantClient().listModels(
                config: config, apiKey: apiKey(for: provider))
            settings.assistantConfig.fetchedModels[raw] = models
            if models.isEmpty {
                fetchErrors[raw] = "No models returned for this provider."
            }
        } catch {
            fetchErrors[raw] = error.localizedDescription
        }
    }

    // MARK: - Migration

    /// Ground truth used to keep its own base-URL setting; the Models module
    /// unifies on one per-provider base URL. Carry an old value forward once.
    private func migrateGroundTruthBaseURLIfNeeded() {
        if settings.assistantConfig.baseURL.isEmpty && !settings.groundTruthBaseURL.isEmpty {
            settings.assistantConfig.baseURL = settings.groundTruthBaseURL
        }
    }
}
