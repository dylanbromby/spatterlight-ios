import UIKit

enum GameFormat: String, Codable {
    case zcode, glulx, unsupported

    var displayName: String {
        switch self {
        case .zcode: return "Z-code"
        case .glulx: return "Glulx"
        case .unsupported: return "Unsupported"
        }
    }

    /// The name of the interpreter framework that plays it.
    var terpName: String? {
        switch self {
        case .zcode: return "bocfel"
        case .glulx: return "glulxe"
        case .unsupported: return nil
        }
    }
}

struct GameRecord: Codable, Identifiable, Hashable {
    /// A signature of the game file, the same one the interpreters use to name their autosave folder.
    var id: String
    var title: String
    var author: String?
    var summary: String?
    var fileName: String
    var format: GameFormat
    var dateAdded: Date
    var lastPlayed: Date?
    var hasCover: Bool = false

    var directoryURL: URL { Library.gamesDirectory.appendingPathComponent(id, isDirectory: true) }
    var fileURL: URL { directoryURL.appendingPathComponent(fileName) }
    var coverURL: URL { directoryURL.appendingPathComponent("cover.png") }
    var savesDirectory: URL { Library.savesDirectory.appendingPathComponent(id, isDirectory: true) }
}

/// What can be read out of a game file without running it.
struct GameFileInfo {
    var format: GameFormat
    var title: String?
    var author: String?
    var summary: String?
    var coverImageData: Data?
}

enum GameInspector {
    static func inspect(data: Data, fileExtension: String) -> GameFileInfo {
        var info = GameFileInfo(format: .unsupported)
        guard data.count > 8 else { return info }

        if data.starts(with: Array("FORM".utf8)), data.subdata(in: 8..<12) == Data("IFRS".utf8) {
            if let blorb = BlorbReader(data: data) {
                if let kind = blorb.executableType {
                    info.format = kind == "ZCOD" ? .zcode : (kind == "GLUL" ? .glulx : .unsupported)
                }
                if let metadata = blorb.metadata {
                    info.title = metadata.title
                    info.author = metadata.author
                    info.summary = metadata.summary
                }
                info.coverImageData = blorb.coverImageData
            }
            return info
        }

        if data.starts(with: Array("Glul".utf8)) {
            info.format = .glulx
            return info
        }

        let ext = fileExtension.lowercased()
        if ["z1", "z2", "z3", "z4", "z5", "z6", "z7", "z8", "dat", "zcode"].contains(ext), (1...8).contains(data[0]) {
            info.format = .zcode
        } else if (1...8).contains(data[0]) && data.count > 64 && ext.isEmpty {
            info.format = .zcode
        }
        return info
    }
}

/// Reads the parts of a Blorb file the library needs.
struct BlorbReader {
    private let data: Data
    private var chunks: [(type: String, range: Range<Int>)] = []
    private var index: [(usage: String, number: Int, offset: Int)] = []

    init?(data: Data) {
        self.data = data
        guard data.count >= 12 else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let type = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let length = Int(BlorbReader.u32(data, offset + 4))
            let start = offset + 8
            let end = min(start + length, data.count)
            guard start <= end else { break }
            chunks.append((type, start..<end))
            offset = end + (length & 1)
        }
        if let ridx = chunks.first(where: { $0.type == "RIdx" }) {
            let count = Int(BlorbReader.u32(data, ridx.range.lowerBound))
            var position = ridx.range.lowerBound + 4
            for _ in 0..<count where position + 12 <= data.count {
                let usage = String(decoding: data[position..<position + 4], as: UTF8.self)
                let number = Int(BlorbReader.u32(data, position + 4))
                let start = Int(BlorbReader.u32(data, position + 8))
                index.append((usage, number, start))
                position += 12
            }
        }
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private func chunk(atOffset offset: Int) -> (type: String, range: Range<Int>)? {
        chunks.first { $0.range.lowerBound - 8 == offset }
    }

    var executableType: String? {
        guard let entry = index.first(where: { $0.usage == "Exec" && $0.number == 0 }) else { return nil }
        return chunk(atOffset: entry.offset)?.type
    }

    var coverImageData: Data? {
        guard let frontispiece = chunks.first(where: { $0.type == "Fspc" }), frontispiece.range.count >= 4 else { return nil }
        let number = Int(BlorbReader.u32(data, frontispiece.range.lowerBound))
        guard let entry = index.first(where: { $0.usage == "Pict" && $0.number == number }),
              let picture = chunk(atOffset: entry.offset) else { return nil }
        return data.subdata(in: picture.range)
    }

    struct Metadata { var title: String?; var author: String?; var summary: String? }

    var metadata: Metadata? {
        guard let chunk = chunks.first(where: { $0.type == "IFmd" }),
              let xml = String(data: data.subdata(in: chunk.range), encoding: .utf8) else { return nil }
        func element(_ name: String) -> String? {
            guard let open = xml.range(of: "<\(name)>"), let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
            let text = String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : XMLEntities.decode(text)
        }
        return Metadata(title: element("title"), author: element("author"), summary: element("description"))
    }
}

enum XMLEntities {
    static func decode(_ string: String) -> String {
        string.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension Notification.Name {
    static let libraryDidChange = Notification.Name("SpatterlightLibraryDidChange")
}

/// The games on this device. Each one is copied into the app's own folder,
/// where the interpreters can read it, with its saved games and autosave.
final class Library {
    static let shared = Library()

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Spatterlight", isDirectory: true)
    }
    static var gamesDirectory: URL { supportDirectory.appendingPathComponent("Games", isDirectory: true) }
    static var savesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Saved Games", isDirectory: true)
    }
    private static var indexURL: URL { supportDirectory.appendingPathComponent("library.json") }

    private(set) var games: [GameRecord] = []

    private init() {
        try? FileManager.default.createDirectory(at: Library.gamesDirectory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Library.indexURL),
              let decoded = try? JSONDecoder().decode([GameRecord].self, from: data) else { return }
        games = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(games) else { return }
        try? FileManager.default.createDirectory(at: Library.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Library.indexURL, options: .atomic)
        NotificationCenter.default.post(name: .libraryDidChange, object: self)
    }

    func game(withID id: String) -> GameRecord? { games.first { $0.id == id } }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "“\(name)” could not be read."
            case .unsupported(let name): return "“\(name)” is not a game this version can play yet. Z-code and Glulx stories work."
            }
        }
    }

    /// Copies a game file into the library. Returns the record, which may be one that was already there.
    @discardableResult
    func importGame(from url: URL) throws -> GameRecord {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        let info = GameInspector.inspect(data: data, fileExtension: url.pathExtension)
        guard info.format != .unsupported else { throw ImportError.unsupported(url.lastPathComponent) }

        let id = FileSignature.signature(from: data)
        if let existing = game(withID: id) { return existing }

        let title = info.title ?? url.deletingPathExtension().lastPathComponent
        var record = GameRecord(id: id, title: title, author: info.author, summary: info.summary,
                                fileName: url.lastPathComponent, format: info.format, dateAdded: Date())
        try FileManager.default.createDirectory(at: record.directoryURL, withIntermediateDirectories: true)
        try data.write(to: record.fileURL, options: .atomic)
        if let cover = info.coverImageData, let image = UIImage(data: cover), let png = image.pngData() {
            try? png.write(to: record.coverURL, options: .atomic)
            record.hasCover = true
        }
        games.append(record)
        save()
        return record
    }

    /// Story files dropped into this app's folder in the Files app are added to the library
    /// and tucked away in an "Added" folder, so the originals are never lost.
    func importFromDocumentsFolder() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let added = documents.appendingPathComponent("Added", isDirectory: true)
        for url in items {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory, !url.lastPathComponent.hasPrefix(".") else { continue }
            guard (try? importGame(from: url)) != nil else { continue }
            try? fm.createDirectory(at: added, withIntermediateDirectories: true)
            var destination = added.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                destination = added.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            }
            try? fm.moveItem(at: url, to: destination)
        }
    }

    func markPlayed(_ game: GameRecord) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].lastPlayed = Date()
        save()
    }

    func remove(_ game: GameRecord) {
        games.removeAll { $0.id == game.id }
        try? FileManager.default.removeItem(at: game.directoryURL)
        for terp in ["glulxe", "bocfel"] { AutosaveStore.discard(for: game, terp: terp) }
        save()
    }

    func rename(_ game: GameRecord, to title: String) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].title = title
        save()
    }

    var recentlyPlayed: [GameRecord] {
        games.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }
}

/// Where an interpreter keeps a game's autosave, and the screen state that goes with it.
enum AutosaveStore {
    /// The Glk library names the folder after the interpreter (see glkimp/fileref.m).
    private static func folderName(for terp: String) -> String {
        switch terp {
        case "glulxe": return "Glulxe Files"
        case "bocfel": return "Bocfel Files"
        default: return terp.capitalized + " Files"
        }
    }

    static func directory(for game: GameRecord, terp: String) -> URL? {
        Library.supportDirectory
            .appendingPathComponent(folderName(for: terp), isDirectory: true)
            .appendingPathComponent("Autosaves", isDirectory: true)
            .appendingPathComponent(game.id, isDirectory: true)
    }

    static func uiSnapshotURL(for game: GameRecord, terp: String) -> URL? {
        directory(for: game, terp: terp)?.appendingPathComponent("screen.snapshot")
    }

    static func hasAutosave(for game: GameRecord, terp: String) -> Bool {
        guard let dir = directory(for: game, terp: terp) else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("autosave.glksave").path) &&
            fm.fileExists(atPath: dir.appendingPathComponent("autosave.plist").path) &&
            fm.fileExists(atPath: dir.appendingPathComponent("screen.snapshot").path)
    }

    static func discard(for game: GameRecord, terp: String) {
        guard let dir = directory(for: game, terp: terp) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
