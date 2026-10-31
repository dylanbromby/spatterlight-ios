import Foundation

/// Infocom box art and maps shipped inside the app (see `iOS/InfocomGameAssets/`).
enum BundledGameAssets {
    struct Catalog: Codable {
        var version: Int
        var games: [String: GameEntry]

        struct GameEntry: Codable {
            var inTheBox: [AssetRef]
            var maps: [AssetRef]
        }

        struct AssetRef: Codable {
            var title: String
            var file: String
        }
    }

    private static let subdirectory = "InfocomGameAssets"

    static var bundleRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(subdirectory, isDirectory: true)
    }

    static func catalog() -> Catalog? {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: subdirectory),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    static func slug(for game: GameRecord, tuid: String? = nil) -> String? {
        InvisiCluesCatalog.slug(forTitle: game.title, ifdbTUID: tuid)
    }

    /// Copies bundled images into the game's library folder (once).
    @discardableResult
    static func install(into game: GameRecord, tuid: String? = nil) -> InvisiCluesAssetFetcher.Manifest? {
        if let existing = InvisiCluesAssetFetcher.shared.manifest(for: game) { return existing }
        guard let slug = slug(for: game, tuid: tuid),
              let entry = catalog()?.games[slug],
              let root = bundleRoot else { return nil }

        let destRoot = InvisiCluesAssetFetcher.shared.assetsDirectory(for: game)
        try? FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)

        func copyAssets(_ refs: [Catalog.AssetRef], folder: String) -> [InvisiCluesAssetFetcher.Manifest.Asset] {
            refs.compactMap { ref in
                let source = root.appendingPathComponent(ref.file)
                guard FileManager.default.fileExists(atPath: source.path) else { return nil }
                let name = (ref.file as NSString).lastPathComponent
                let dest = destRoot.appendingPathComponent("\(folder)/\(name)", isDirectory: false)
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.copyItem(at: source, to: dest)
                }
                return InvisiCluesAssetFetcher.Manifest.Asset(
                    title: ref.title,
                    fileName: "\(folder)/\(name)",
                    sourceURL: ref.file
                )
            }
        }

        let box = copyAssets(entry.inTheBox, folder: "box")
        let maps = copyAssets(entry.maps, folder: "maps")
        guard !box.isEmpty || !maps.isEmpty else { return nil }

        let manifest = InvisiCluesAssetFetcher.Manifest(
            version: InvisiCluesAssetFetcher.Manifest.currentVersion,
            slug: slug,
            fetchedAt: Date(),
            inTheBox: box,
            maps: maps
        )
        let manifestURL = destRoot.appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
        return manifest
    }
}
