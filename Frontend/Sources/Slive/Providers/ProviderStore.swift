import Combine
import Foundation
import SwiftUI

/// The provider/model configuration module — one owner for everything about
/// "which AI can Slive talk to". Surfaces that USE a model — Assistant,
/// Training — only pick a provider and a model id; everything secret or
/// provider-global is entered once in the Models page and read through here.
///
/// A thin facade over the three parts, kept so views observe one object:
/// `CredentialStore` (Keychain: API keys + HF token), `LocalModelsStore`
/// (HF cache inventory + downloads) and `ModelListCache` (live model lists).
@MainActor
final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()

    let credentials: CredentialStore
    let local: LocalModelsStore
    let modelLists: ModelListCache

    private let settings = Settings.shared
    private var forwarding: Set<AnyCancellable> = []

    /// Bumped on any credential change so key pills refresh wherever they live.
    @Published private(set) var keyEdition = 0

    private init() {
        let credentials = CredentialStore.shared
        let local = LocalModelsStore(credentials: credentials)
        self.credentials = credentials
        self.local = local
        modelLists = ModelListCache(settings: .shared, credentials: credentials, localModels: local)
        // Views observe this facade; re-publish the parts' changes.
        local.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
        modelLists.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarding)
        migrateGroundTruthBaseURLIfNeeded()
    }

    // MARK: - Credentials (Keychain)

    func apiKey(for provider: AssistantProvider) -> String {
        credentials.apiKey(for: provider)
    }

    func setAPIKey(_ value: String, for provider: AssistantProvider) {
        credentials.setAPIKey(value, for: provider)
        settings.objectWillChange.send()   // Settings-observing views re-read keys too
        keyEdition += 1
    }

    func hasKey(_ provider: AssistantProvider) -> Bool {
        credentials.hasKey(provider)
    }

    var huggingFaceToken: String { credentials.huggingFaceToken }

    func setHuggingFaceToken(_ value: String) {
        credentials.setHuggingFaceToken(value)
        keyEdition += 1
    }

    // MARK: - Local models (download + read the HF cache, all in the backend)

    var localModels: [LocalCachedModel] { local.models }
    var localLoading: Bool { local.loading }
    var localDownloading: String? { local.downloading }
    var localError: String? { local.error }

    func refreshLocalCache() async { await local.refresh() }
    func downloadLocalModel(_ repoID: String) async { await local.download(repoID) }
    func deleteLocalModel(_ repoID: String) async { await local.delete(repoID) }

    // MARK: - Provider-global config

    /// The one base URL a provider needs (OpenAI-compatible only).
    func baseURL(for provider: AssistantProvider) -> String {
        settings.assistantConfig.baseURL(for: provider)
    }

    // MARK: - Live model lists

    func models(for provider: AssistantProvider) -> [String] { modelLists.models(for: provider) }
    func isFetching(_ provider: AssistantProvider) -> Bool { modelLists.isFetching(provider) }
    func fetchError(for provider: AssistantProvider) -> String? { modelLists.fetchError(for: provider) }

    /// `ModelListCache.refreshModels(for:)` — the one entry point.
    func fetchModels(for provider: AssistantProvider) async {
        await modelLists.refreshModels(for: provider)
    }

    /// The same refresh, started from a view (Refresh / Fetch buttons, picking
    /// a provider) — views never start the task themselves. `onlyIfEmpty`:
    /// picking Local is explicit intent, so list what's downloaded unless a
    /// list is already remembered.
    func requestModels(for provider: AssistantProvider, onlyIfEmpty: Bool = false) {
        if onlyIfEmpty && !models(for: provider).isEmpty { return }
        Task { await fetchModels(for: provider) }
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
