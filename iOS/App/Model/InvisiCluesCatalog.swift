import Foundation

/// Maps IFDB entries and common Infocom titles to InvisiClues.org page slugs.
enum InvisiCluesCatalog {
    /// IFDB TUID → invisiclues.org slug (game page `/slug`, hints `/invisiclues/slug`).
    static let tuidToSlug: [String: String] = [
        "4h62dvooeg9ajtfa": "amfv",
        "zoohwv5nqye7up2t": "arthur",
        "b0i6bx7g4rkrekgg": "ballyhoo",
        "9h6o1charof548ii": "beyond-zork",
        "7epwz167lgruvm0u": "border-zone",
        "zjyxds3s57pgis3x": "bureaucracy",
        "4ao65o1u0xuvj8jf": "cutthroats",
        "p976o7x5ies9ltdh": "deadline",
        "vu4xhul3abknifcr": "enchanter",
        "ouv80gvsl32xlion": "hhgttg",
        "jnfkbgdgopwfqist": "hhijinx",
        "anu79a4n1jedg5mm": "infidel",
        "3p9fdt4fxr2goctw": "lgop",
        "jhbd0kja1t57uop": "lurking-horror",
        "c66u816v8kx2jzm2": "moonmist",
        "zxb8pq3qrkvdob4i": "nord-and-bert",
        "xe6kb3cuqwie2q38": "planetfall",
        "ddagftras22bnz8h": "plundered-hearts",
        "56wb8hflec2isvzm": "seastalker",
        "j8lmspy4iz73mx26": "sherlock",
        "w3pz3v8wckaw1wgb": "shogun",
        "lidg5nx9ig0bwk55": "sorcerer",
        "wqsmrahzozosu3r": "spellbreaker",
        "y42oje3ryqi6lohn": "starcross",
        "9nlbhqnlyb169uge": "stationfall",
        "tdbss1ekrp4ua7h4": "suspect",
        "t47hei9uq10xoar8": "suspended",
        "j18kjz80hxjtyayw": "trinity",
        "z02joykzh66wfhcl": "wishbringer",
        "6963a47vqgms8wi0": "witness",
        "17coplfu323xif76": "zork-zero",
        "0dbnusxunq7fw5ro": "zork-i",
        "yzzm4puxyjakk8c4": "zork-ii",
        "vrsot1zgy1wfcdru": "zork-iii",
    ]

    private static let titleToSlug: [String: String] = [
        "zork i": "zork-i",
        "zork ii": "zork-ii",
        "zork iii": "zork-iii",
        "zork zero": "zork-zero",
        "zork zero the revenge of megaboz": "zork-zero",
        "zork 0": "zork-zero",
        "beyond zork": "beyond-zork",
        "border zone": "border-zone",
        "hitchhiker's guide to the galaxy": "hhgttg",
        "the hitchhiker's guide to the galaxy": "hhgttg",
        "hollywood hijinx": "hhijinx",
        "leather goddesses of phobos": "lgop",
        "lurking horror": "lurking-horror",
        "the lurking horror": "lurking-horror",
        "nord and bert couldn't make head or tail of it": "nord-and-bert",
        "plundered hearts": "plundered-hearts",
        "a mind forever voyaging": "amfv",
        "arthur the quest for excalibur": "arthur",
        "zork the undiscovered underground": "zork-zero",
    ]

    static func slug(forTitle title: String, ifdbTUID: String?) -> String? {
        if let ifdbTUID, let slug = tuidToSlug[ifdbTUID] { return slug }
        let norm = normalize(title)
        if let slug = titleToSlug[norm] { return slug }
        for (key, slug) in titleToSlug where norm.contains(key) { return slug }
        let kebab = kebabCase(from: title)
        return kebab.isEmpty ? nil : kebab
    }

    private static func normalize(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: #":.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9\s']"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func kebabCase(from title: String) -> String {
        let norm = normalize(title)
        let words = norm.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "" }
        return words.joined(separator: "-")
    }
}
