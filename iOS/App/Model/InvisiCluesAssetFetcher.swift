import Foundation

/// Installs bundled Infocom game assets (box feelies + map scans) into each library entry.
final class InvisiCluesAssetFetcher {
    static let shared = InvisiCluesAssetFetcher()

    private let queue = DispatchQueue(label: "com.roaringsky.spatterlight.game-assets", qos: .utility)

    struct Manifest: Codable {
        static let currentVersion = 1
        var version: Int
        var slug: String
        var fetchedAt: Date
        var inTheBox: [Asset]
        var maps: [Asset]

        struct Asset: Codable {
            var title: String
            var fileName: String
            var sourceURL: String
        }
    }

    func schedule(gameID: String) {
        queue.async { [weak self] in self?.install(gameID: gameID) }
    }

    func scheduleMissingAssets() {
        for game in Library.shared.games where manifest(for: game) == nil {
            schedule(gameID: game.id)
        }
    }

    func manifest(for game: GameRecord) -> Manifest? {
        let url = manifestURL(for: game)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    func assetsDirectory(for game: GameRecord) -> URL {
        game.directoryURL.appendingPathComponent("invisiclues", isDirectory: true)
    }

    func fileURL(for game: GameRecord, asset: Manifest.Asset) -> URL {
        assetsDirectory(for: game).appendingPathComponent(asset.fileName)
    }

    private func manifestURL(for game: GameRecord) -> URL {
        assetsDirectory(for: game).appendingPathComponent("manifest.json")
    }

    enum InstallError: LocalizedError {
        case notBundled
        case unknownTitle

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "No bundled assets for this game. Rebuild the app after running tools/fetch_infocom_game_assets.py."
            case .unknownTitle:
                return "This story is not linked to a bundled Infocom title."
            }
        }
    }

    func installNow(gameID: String, completion: @escaping (Result<Manifest, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.installResult(gameID: gameID)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func installResult(gameID: String) -> Result<Manifest, Error> {
        guard let game = Library.shared.game(withID: gameID) else { return .failure(InstallError.notBundled) }
        if let manifest = manifest(for: game) { return .success(manifest) }
        guard BundledGameAssets.slug(for: game) != nil else { return .failure(InstallError.unknownTitle) }
        guard let manifest = BundledGameAssets.install(into: game) else { return .failure(InstallError.notBundled) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .libraryDidChange, object: Library.shared)
        }
        return .success(manifest)
    }

    private func install(gameID: String) {
        _ = installResult(gameID: gameID)
    }
}

extension GameRecord {
    var hasInvisiCluesAssets: Bool {
        InvisiCluesAssetFetcher.shared.manifest(for: self) != nil
    }
}
