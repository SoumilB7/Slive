import Foundation

/// A model's state as the pickers show it.
enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(Double)   // 0…1
    case preparing(String)     // the engine's load stage (e.g. "Loading")
    case ready
    case failed(String)
}

/// Where the transcription parts post a model's status: `TranscriptionModel`'s
/// published `statuses` in the app, a plain dictionary in the self-tests.
@MainActor
protocol ModelStatusBoard: AnyObject {
    func status(for model: String) -> ModelStatus
    func setStatus(_ status: ModelStatus, for model: String)
}

/// One engine's models on disk: whether a model's files are there, fetching
/// them, deleting them. What every engine shares — the basket, the
/// unfinished-download marker, one download per model, the stall watchdog and
/// the status it drives — is `ModelDownloads`, so a storage knows only its
/// own files.
@MainActor
protocol ModelStorage: AnyObject {
    /// `id` is complete on disk, bundled, or installed locally. (An
    /// unfinished download's marker is checked before this.)
    func hasFiles(_ id: String) -> Bool
    /// Installed outside Slive's downloads (a fine-tune): Download and
    /// Re-download just load it, and it's never deleted.
    func isInstalledLocally(_ id: String) -> Bool
    /// Fetch `id`'s files into the basket. Every `progress` call keeps the
    /// stall watchdog quiet. Returns a folder to stamp complete, or nil when
    /// the engine's own completeness check is enough.
    func fetch(_ id: String, progress: DownloadProgress) async throws -> URL?
    /// Delete `id`'s downloaded files (never a bundled or installed model).
    func remove(_ id: String)
}

/// A download's signs of life (any thread).
struct DownloadProgress: Sendable {
    /// 0…1 as files arrive.
    let report: @Sendable (Double) -> Void
    /// Progress without a fraction (e.g. the tokenizer fetch starting).
    let alive: @Sendable () -> Void
}

/// The one folder every downloaded model lives under — the app's data dir
/// (`~/Library/Application Support/Slive/Models`), or a temp dir in tests.
struct ModelBasket {
    let root: URL

    static let standard = ModelBasket(root: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Slive/Models", isDirectory: true))

    /// The basket, created on first use.
    var url: URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Written into a model's folder once its download (+ tokenizer) finished.
    static let completeMarker = ".slive-complete"

    func stampComplete(_ folder: URL) {
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent(Self.completeMarker).path, contents: nil)
    }

    static func isStamped(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(completeMarker).path)
    }

    /// Exists while `model`'s download is unfinished.
    func pendingMarker(_ model: String) -> URL {
        url.appendingPathComponent(".downloading-\(model)")
    }

    /// One-time: move any prior ~/Documents/huggingface downloads into the basket.
    func migrateOldDownloads(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let old = home.appendingPathComponent("Documents/huggingface/models")
        let new = url.appendingPathComponent("models")
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
