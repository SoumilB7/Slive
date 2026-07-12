import Foundation
import SwiftUI

/// The provider/model configuration module — one owner for everything about
/// "which AI can Slive talk to": credentials (Keychain), the OpenAI-compatible
/// base URL, live model lists, and the Local / Hugging Face
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

    // MARK: - Local (Hugging Face) — the token slot

    /// Keychain account for the Hugging Face access token used by the
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

    // MARK: - Local models (download + read the HF cache, all in the backend)

    /// Models currently in the on-disk HF cache (largest first).
    @Published private(set) var localModels: [LocalCachedModel] = []
    /// True while re-reading the cache.
    @Published private(set) var localLoading = false
    /// repo_id of the download in flight, if any (one at a time).
    @Published private(set) var localDownloading: String?
    @Published private(set) var localError: String?

    private let localClient = LocalModelsClient()

    /// Re-read the HF cache (starts the lazy backend first).
    func refreshLocalCache() async {
        localLoading = true
        localError = nil
        defer { localLoading = false }
        guard await BackendManager.shared.ensureHealthy() else {
            localError = "Couldn't start the local backend."
            return
        }
        do {
            localModels = try await localClient.cachedModels()
        } catch {
            localError = error.localizedDescription
        }
    }

    /// Download `repoID` into the standard HF cache via the backend, polling the
    /// job to completion, then refresh the cache list.
    func downloadLocalModel(_ repoID: String) async {
        let id = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, localDownloading == nil else { return }
        localError = nil
        guard await BackendManager.shared.ensureHealthy() else {
            localError = "Couldn't start the local backend."
            return
        }
        localDownloading = id
        defer { localDownloading = nil }
        do {
            let jobID = try await localClient.startDownload(repoID: id, token: huggingFaceToken)
            while true {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let job = try await localClient.downloadStatus(jobID: jobID)
                if job.state == "done" { break }
                if job.state == "error" {
                    localError = job.message.isEmpty ? "Download failed." : job.message
                    break
                }
            }
            await refreshLocalCache()
        } catch {
            localError = error.localizedDescription
        }
    }

    /// Remove a cached model from disk, then refresh.
    func deleteLocalModel(_ repoID: String) async {
        localError = nil
        do {
            try await localClient.delete(repoID: repoID)
            await refreshLocalCache()
        } catch {
            localError = error.localizedDescription
        }
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

        // Local "fetch" is a cache re-scan: the pickable models are whatever is
        // downloaded on disk, above the same size floor the Models page shows.
        if provider.isLocal {
            await refreshLocalCache()
            let ids = localModels
                .filter { $0.size_bytes >= LocalCachedModel.minPickableBytes }
                .map(\.repo_id)
            settings.assistantConfig.fetchedModels[raw] = ids
            if let err = localError {
                fetchErrors[raw] = err
            } else if ids.isEmpty {
                fetchErrors[raw] = "No downloaded models yet — add one in Models → Local."
            }
            return
        }

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
