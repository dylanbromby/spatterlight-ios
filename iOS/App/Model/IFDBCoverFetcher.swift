import Foundation
import UIKit

/// Pulls cover art and bibliographic data from IFDB when a story file has none embedded.
final class IFDBCoverFetcher {
    static let shared = IFDBCoverFetcher()

    private let queue = DispatchQueue(label: "com.roaringsky.spatterlight.ifdb", qos: .utility)
    private var active = Set<String>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    func schedule(gameID: String) {
        guard Settings.shared.fetchIFDBCovers else { return }
        queue.async { [weak self] in self?.sync(gameID: gameID) }
    }

    func scheduleMissingCovers() {
        guard Settings.shared.fetchIFDBCovers else { return }
        for game in Library.shared.games where needsSync(game) {
            schedule(gameID: game.id)
        }
    }

    private func needsSync(_ game: GameRecord) -> Bool {
        !game.hasCover || (game.summary ?? "").isEmpty
    }

    private func sync(gameID: String) {
        guard active.insert(gameID).inserted else { return }
        defer { active.remove(gameID) }

        guard let game = Library.shared.game(withID: gameID), needsSync(game),
              let data = try? Data(contentsOf: game.fileURL, options: .mappedIfSafe) else { return }

        var payload: [String: Any]?
        for ifid in StoryIFID.ifids(from: data, format: game.format) {
            if let json = viewGameJSON(ifid: ifid) {
                payload = json
                break
            }
        }
        if payload == nil, let tuid = searchTUID(forTitle: game.title) {
            payload = viewGameJSON(tuid: tuid)
        }
        guard let json = payload, let parsed = parseListing(json) else { return }

        var coverData = parsed.coverData
        if coverData == nil, let url = parsed.coverURL {
            coverData = downloadImage(from: url)
        }

        DispatchQueue.main.async {
            Library.shared.applyIFDBListing(gameID: gameID, parsed: parsed, coverData: coverData)
        }
    }

    struct ParsedListing {
        var title: String?
        var author: String?
        var summary: String?
        var coverURL: URL?
        var coverData: Data?
    }

    private func parseListing(_ json: [String: Any]) -> ParsedListing? {
        if (json["errorCode"] as? String) != nil { return nil }
        let bib = json["bibliographic"] as? [String: Any]
        let ifdb = json["ifdb"] as? [String: Any]
        let coverLink = (ifdb?["coverart"] as? [String: Any])?["url"] as? String
        let title = bib?["title"] as? String
        let author = bib?["author"] as? String
        let html = bib?["description"] as? String
        let summary = html.flatMap { Self.plainText(fromHTML: $0) }.flatMap { Self.cleanSummary($0) }
        if title == nil, author == nil, (summary ?? "").isEmpty, coverLink == nil { return nil }
        return ParsedListing(title: title, author: author, summary: summary,
                             coverURL: coverLink.flatMap { URL(string: $0) }, coverData: nil)
    }

    private func viewGameJSON(ifid: String) -> [String: Any]? {
        guard let encoded = ifid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://ifdb.org/viewgame?json&ifid=\(encoded)") else { return nil }
        guard let data = syncGET(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["errorCode"] as? String) == nil ? json : nil
    }

    private func viewGameJSON(tuid: String) -> [String: Any]? {
        guard let url = URL(string: "https://ifdb.org/viewgame?json&id=\(tuid)") else { return nil }
        guard let data = syncGET(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["errorCode"] as? String) == nil ? json : nil
    }

    private func searchTUID(forTitle title: String) -> String? {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://ifdb.org/search?json&sortby=ttl&searchfor=game&query=\(encoded)"),
              let data = syncGET(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let games = json["games"] as? [[String: Any]] else { return nil }

        let want = normalize(query)
        var best: (score: Int, tuid: String)?
        for game in games {
            guard let tuid = game["tuid"] as? String, let found = game["title"] as? String else { continue }
            let norm = normalize(found)
            var score = 0
            if norm == want { score = 100 }
            else if norm.hasPrefix(want) || want.hasPrefix(norm) { score = 80 }
            else if norm.contains(want) || want.contains(norm) { score = 50 }
            else { continue }
            if best == nil || score > best!.score { best = (score, tuid) }
        }
        return best?.tuid
    }

    private func normalize(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func downloadImage(from url: URL) -> Data? {
        var fetch = url
        if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = parts.queryItems ?? []
            if !items.contains(where: { $0.name == "thumbnail" }) {
                items.append(URLQueryItem(name: "thumbnail", value: "336x336"))
                parts.queryItems = items
                fetch = parts.url ?? url
            }
        }
        guard let data = syncGET(fetch), UIImage(data: data) != nil else { return nil }
        return data
    }

    private func syncGET(_ url: URL) -> Data? {
        var result: Data?
        let group = DispatchGroup()
        group.enter()
        session.dataTask(with: url) { data, response, _ in
            defer { group.leave() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else { return }
            result = data
        }.resume()
        group.wait()
        return result
    }

    static func plainText(fromHTML html: String) -> String? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let text = try? NSAttributedString(data: data, options: options, documentAttributes: nil).string else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// IFDB descriptions often end with catalog lines like "[--blurb from …]".
    static func cleanSummary(_ text: String?) -> String? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: #"\[--[^\]]+\]"#, with: "", options: .regularExpression)
        while let range = s.range(of: #"\n{2,}"#, options: .regularExpression) {
            s.replaceSubrange(range, with: "\n")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
