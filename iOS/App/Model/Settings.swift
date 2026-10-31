import UIKit

/// How the reading surface looks. Mirrors the idea of a theme in the macOS app,
/// reduced to what makes sense on a phone.
struct ReaderTheme: Codable, Equatable {
    enum Palette: String, Codable, CaseIterable, Identifiable {
        case system, light, dark, sepia, black
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            case .sepia: return "Sepia"
            case .black: return "Black"
            }
        }
    }

    enum BodyFont: String, Codable, CaseIterable, Identifiable {
        case newYork, system, georgia, palatino, charter, iowan, avenir
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newYork: return "New York"
            case .system: return "San Francisco"
            case .georgia: return "Georgia"
            case .palatino: return "Palatino"
            case .charter: return "Charter"
            case .iowan: return "Iowan Old Style"
            case .avenir: return "Avenir Next"
            }
        }
        /// nil means use the system face with the serif or default design.
        var postScriptFamily: String? {
            switch self {
            case .newYork, .system: return nil
            case .georgia: return "Georgia"
            case .palatino: return "Palatino"
            case .charter: return "Charter"
            case .iowan: return "Iowan Old Style"
            case .avenir: return "Avenir Next"
            }
        }
    }

    enum FixedFont: String, Codable, CaseIterable, Identifiable {
        case systemMono, menlo, courier
        var id: String { rawValue }
        var title: String {
            switch self {
            case .systemMono: return "SF Mono"
            case .menlo: return "Menlo"
            case .courier: return "Courier New"
            }
        }
        var family: String? {
            switch self {
            case .systemMono: return nil
            case .menlo: return "Menlo"
            case .courier: return "Courier New"
            }
        }
    }

    var palette: Palette = .system
    var bodyFont: BodyFont = .newYork
    var fixedFont: FixedFont = .systemMono
    /// Point size at the default Dynamic Type setting.
    var fontSize: CGFloat = 18
    var gridFontSize: CGFloat = 14
    /// Extra space between lines, in points.
    var lineSpacing: CGFloat = 3
    /// Side margin of the text, in points.
    var margin: CGFloat = 16
    /// Follow the system's text size setting (Dynamic Type).
    var followsDynamicType: Bool = true
    /// Show the typed command in a different colour from the story text.
    var accentInput: Bool = true
    var justify: Bool = false

    struct Colors {
        var background: UIColor
        var text: UIColor
        var input: UIColor
        var gridBackground: UIColor
        var gridText: UIColor
        var link: UIColor
        var isDark: Bool
    }

    /// The colours for a palette. `systemIsDark` decides what Match System means.
    func colors(systemIsDark: Bool) -> Colors {
        func rgb(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        let resolved: Palette = palette == .system ? (systemIsDark ? .dark : .light) : palette
        switch resolved {
        case .light, .system:
            return Colors(background: rgb(0xFFFFFF), text: rgb(0x1C1C1E), input: rgb(0x0A5BC4),
                          gridBackground: rgb(0xE9E9EE), gridText: rgb(0x1C1C1E), link: rgb(0x0A5BC4), isDark: false)
        case .dark:
            return Colors(background: rgb(0x1C1C1E), text: rgb(0xE6E6EA), input: rgb(0x7DB7FF),
                          gridBackground: rgb(0x2C2C2E), gridText: rgb(0xE6E6EA), link: rgb(0x7DB7FF), isDark: true)
        case .sepia:
            return Colors(background: rgb(0xF4ECD8), text: rgb(0x433422), input: rgb(0x8A3B12),
                          gridBackground: rgb(0xE6DCC2), gridText: rgb(0x433422), link: rgb(0x8A3B12), isDark: false)
        case .black:
            return Colors(background: rgb(0x000000), text: rgb(0xD2D2D6), input: rgb(0x7DB7FF),
                          gridBackground: rgb(0x151517), gridText: rgb(0xD2D2D6), link: rgb(0x7DB7FF), isDark: true)
        }
    }
}

/// What the second pane shows when the screen is wide enough to have one.
enum SidePaneContent: String, Codable, CaseIterable, Identifiable {
    case library, notes, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "Library"
        case .notes: return "Notes"
        case .history: return "History"
        }
    }
    var symbol: String {
        switch self {
        case .library: return "books.vertical"
        case .notes: return "note.text"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Whether to show the story next to a side pane.
enum PaneLayout: String, Codable, CaseIterable, Identifiable {
    /// Two panes when the window is wide (an unfolded device, an iPad), one otherwise.
    case automatic
    /// Two panes even on a narrow screen.
    case alwaysDual
    /// Never.
    case single
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .alwaysDual: return "Always two panes"
        case .single: return "Single pane"
        }
    }
}

/// Where a map window (a picture window above the story) goes on a wide, landscape screen.
enum MapPlacement: String, Codable, CaseIterable, Identifiable {
    /// The story on one side, the map on the other.
    case beside
    /// Stacked, as the story asks for it.
    case above
    var id: String { rawValue }
    var title: String { self == .beside ? "Beside the story" : "Above the story" }
}

enum PaneSide: String, Codable, CaseIterable, Identifiable {
    case leading, trailing
    var id: String { rawValue }
    var title: String { self == .leading ? "Left" : "Right" }
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("SpatterlightSettingsDidChange")
}

/// The user's choices, persisted in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private func load<T: Decodable>(_ key: String, default value: T) -> T {
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        // A plain string (for instance `-paneLayout alwaysDual` on the command line) stands for a simple value.
        if let text = defaults.string(forKey: key), let decoded = try? JSONDecoder().decode(T.self, from: Data("\"\(text)\"".utf8)) {
            return decoded
        }
        return value
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

    var theme: ReaderTheme {
        get { load("theme", default: ReaderTheme()) }
        set { save(newValue, key: "theme") }
    }

    var paneLayout: PaneLayout {
        get { load("paneLayout", default: .automatic) }
        set { save(newValue, key: "paneLayout") }
    }

    var sidePane: SidePaneContent {
        get { load("sidePane", default: .library) }
        set { save(newValue, key: "sidePane") }
    }

    var sidePaneSide: PaneSide {
        get { load("sidePaneSide", default: .leading) }
        set { save(newValue, key: "sidePaneSide") }
    }

    /// Widest the side pane may get, as a fraction of the window.
    var sidePaneWidthFraction: Double {
        get { load("sidePaneWidthFraction", default: 0.38) }
        set { save(newValue, key: "sidePaneWidthFraction") }
    }

    /// Keep what you were playing when the app is closed, and pick it up again.
    var autosave: Bool {
        get { load("autosave", default: true) }
        set { save(newValue, key: "autosave") }
    }

    var showGraphics: Bool {
        get { load("showGraphics", default: true) }
        set { save(newValue, key: "showGraphics") }
    }

    /// Haptic tick when you send a command.
    var haptics: Bool {
        get { load("haptics", default: true) }
        set { save(newValue, key: "haptics") }
    }

    /// Speak new story text through VoiceOver when it is on.
    var announceText: Bool {
        get { load("announceText", default: true) }
        set { save(newValue, key: "announceText") }
    }

    /// Show the row of arrow, space and return keys while the game waits for a key.
    var showKeyRow: Bool {
        get { load("showKeyRow", default: true) }
        set { save(newValue, key: "showKeyRow") }
    }

    var mapPlacement: MapPlacement {
        get { load("mapPlacement", default: .beside) }
        set { save(newValue, key: "mapPlacement") }
    }

    /// In portrait on a wide screen, float the map over the story's corner instead of stacking it above.
    var mapFloats: Bool {
        get { load("mapFloats", default: true) }
        set { save(newValue, key: "mapFloats") }
    }

    /// Whether a story's map is showing. Changed from the map button, so it does not restyle everything.
    var mapVisible: Bool {
        get { defaults.object(forKey: "mapVisible") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mapVisible") }
    }

    /// Which Z-machine interpreter number Bocfel reports (1-11); 6 is IBM PC.
    var zMachineTerp: Int {
        get { load("zMachineTerp", default: 6) }
        set { save(newValue, key: "zMachineTerp") }
    }

    /// When a story has no embedded cover, look up cover art on IFDB and save it locally.
    var fetchIFDBCovers: Bool {
        get { load("fetchIFDBCovers", default: true) }
        set { save(newValue, key: "fetchIFDBCovers") }
    }

}
