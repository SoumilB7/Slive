import Foundation

/// The Local provider's models: what's in the on-disk Hugging Face cache,
/// plus downloads into it and deletes from it (both through the backend).
@MainActor
final class LocalModelsStore: ObservableObject {
    /// Models currently in the on-disk HF cache (largest first).
    @Published private(set) var models: [LocalCachedModel] = []
    /// True while re-reading the cache.
    @Published private(set) var loading = false
    /// repo_id of the download in flight, if any (one at a time).
    @Published private(set) var downloading: String?
    @Published private(set) var error: String?

    private let credentials: CredentialStore
    private let client = LocalModelsClient()

    init(credentials: CredentialStore) {
        self.credentials = credentials
    }

    /// Repo ids worth offering in a picker: downloads above the size floor
    /// the Models page shows (the rest are config-only repos).
    var pickableIDs: [String] {
        models.filter { $0.size_bytes >= LocalCachedModel.minPickableBytes }.map(\.repo_id)
    }

    /// Re-read the HF cache — from disk, without starting the backend.
    func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        models = await Task.detached(priority: .utility) { LocalCachedModel.scanCache() }.value
    }

    /// Download `repoID` into the standard HF cache via the backend, polling the
    /// job to completion, then refresh the cache list.
    func download(_ repoID: String) async {
        let id = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, downloading == nil else { return }
        error = nil
        guard await BackendManager.shared.ensureHealthy() else {
            error = BackendManager.shared.lastSpawnError ?? "Local server didn't start."
            return
        }
        downloading = id
        defer { downloading = nil }
        var failure: String?
        do {
            let jobID = try await client.startDownload(repoID: id, token: credentials.huggingFaceToken)
            // No time cap: a multi-GB model on a slow line can take hours. The
            // loop ends on done/error, a vanished job (server restarted), or a
            // server that stays unreachable — one blip doesn't end it.
            var misses = 0
            while true {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let job: LocalDownloadJob
                do {
                    job = try await client.downloadStatus(jobID: jobID)
                    misses = 0
                } catch let error as LocalModelsClient.ServerError {
                    throw error
                } catch {
                    misses += 1
                    if misses >= 5 { throw error }
                    continue
                }
                if job.state == "done" { break }
                if job.state == "error" {
                    failure = job.message.isEmpty ? "Download failed." : job.message
                    break
                }
            }
        } catch {
            failure = error.localizedDescription
        }
        // Re-read the cache first: it clears `error`, and the failure
        // must stay on screen (it used to vanish in the same turn).
        await refresh()
        self.error = failure
    }

    /// Remove a cached model from disk, then refresh.
    func delete(_ repoID: String) async {
        error = nil
        do {
            try await client.delete(repoID: repoID)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
