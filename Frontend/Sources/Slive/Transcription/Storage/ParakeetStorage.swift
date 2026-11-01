import Foundation

/// Parakeet models in the basket (`<basket>/parakeet/<FluidAudio's folder>`):
/// FluidAudio's own completeness check, its download (or a clone of its
/// shared cache) — see `ParakeetEngine`'s provisioning.
@MainActor
final class ParakeetStorage: ModelStorage {
    let basket: ModelBasket

    init(basket: ModelBasket) { self.basket = basket }

    func hasFiles(_ id: String) -> Bool {
        guard let model = ParakeetModel(rawValue: id) else { return false }
        return ParakeetEngine.isDownloaded(model, basket: basket.url)
    }

    func isInstalledLocally(_ id: String) -> Bool { false }

    func fetch(_ id: String, progress: DownloadProgress) async throws -> URL? {
        guard let model = ParakeetModel(rawValue: id) else { throw CocoaError(.fileNoSuchFile) }
        try await ParakeetEngine.download(model, basket: basket.url, progress: progress.report)
        return nil
    }

    func remove(_ id: String) {
        guard let model = ParakeetModel(rawValue: id) else { return }
        ParakeetEngine.remove(model, basket: basket.url)
    }

    func directory(for model: ParakeetModel) -> URL {
        ParakeetEngine.directory(for: model, basket: basket.url)
    }
}
