import Foundation

/// Live model lists per provider, shared by every surface that picks a model
/// (Assistant, ground truth, the Models page). Lists are remembered in
/// `AssistantConfig.fetchedModels` so pickers stay filled across launches;
/// they only change through `refreshModels(for:)`.
@MainActor
final class ModelListCache: ObservableObject {
    /// Providers (rawValue) with a live model-list fetch in flight.
    @Published private(set) var fetching: Set<String> = []
    /// Last fetch error per provider (rawValue). Cleared on the next fetch.
    @Published private(set) var fetchErrors: [String: String] = [:]

    private let settings: Settings
    private let credentials: CredentialStore
    private let localModels: LocalModelsStore

    init(settings: Settings, credentials: CredentialStore, localModels: LocalModelsStore) {
        self.settings = settings
        self.credentials = credentials
        self.localModels = localModels
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

    /// Fetch the provider's live model list and remember it. Local's "fetch"
    /// is a cache re-scan; others go through the local backend (started
    /// lazily if needed); a provider with neither (Whisper — picked from
    /// WhisperModelChoice) has nothing to fetch.
    func refreshModels(for provider: AssistantProvider) async {
        let raw = provider.rawValue
        guard provider.isLocal || provider.has(.listModels) else { return }
        guard !fetching.contains(raw) else { return }
        fetching.insert(raw)
        fetchErrors[raw] = nil
        defer { fetching.remove(raw) }

        // Local "fetch" is a cache re-scan: the pickable models are whatever is
        // downloaded on disk, above the same size floor the Models page shows.
        if provider.isLocal {
            await localModels.refresh()
            let ids = localModels.pickableIDs
            settings.assistantConfig.fetchedModels[raw] = ids
            if let err = localModels.error {
                fetchErrors[raw] = err
            } else if ids.isEmpty {
                fetchErrors[raw] = "No local models."
            }
            return
        }

        guard await BackendManager.shared.ensureHealthy() else {
            fetchErrors[raw] = "Local server didn't start."
            return
        }
        var config = settings.assistantConfig
        config.provider = provider
        config.baseURL = config.baseURL(for: provider)
        do {
            let models = try await AssistantClient().listModels(
                config: config, apiKey: credentials.apiKey(for: provider))
            settings.assistantConfig.fetchedModels[raw] = models
            if models.isEmpty {
                fetchErrors[raw] = "No models found."
            }
        } catch {
            fetchErrors[raw] = error.localizedDescription
        }
    }
}
