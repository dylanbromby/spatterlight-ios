import UIKit
import SwiftUI

/// The shell of the app: a side pane (library, notes or commands) and the story.
/// On a narrow screen the side pane is the library you come back to; on a wide
/// one, such as an unfolded device or an iPad, the two sit side by side.
final class RootViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let sidePane = SidePaneViewController()
    private let sideNavigation: UINavigationController
    private let detailNavigation: UINavigationController
    private let placeholder = PlaceholderViewController()
    private var lastWideOverride: Bool?

    init() {
        sideNavigation = UINavigationController(rootViewController: sidePane)
        detailNavigation = UINavigationController(rootViewController: placeholder)
        super.init(style: .doubleColumn)
        delegate = self
        setViewController(sideNavigation, for: .primary)
        setViewController(detailNavigation, for: .secondary)
        sidePane.onOpenGame = { [weak self] game in self?.open(game) }
        sidePane.onSettings = { [weak self] in self?.showSettings() }
        placeholder.onOpenSettings = { [weak self] in self?.showSettings() }
        preferredSplitBehavior = .tile
        presentsWithGesture = true
        applyLayoutSettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(applyLayoutSettings), name: .settingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restartRequested(_:)), name: .restartGameRequested, object: nil)
        let theme = Settings.shared.theme
        overrideUserInterfaceStyle = theme.palette == .system ? .unspecified : (theme.colors(systemIsDark: false).isDark ? .dark : .light)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `-OpenGame <title>` on the command line opens a story at launch (handy for testing).
        if let title = UserDefaults.standard.string(forKey: "OpenGame"),
           let game = Library.shared.games.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
            open(game)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "ShowSettings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.showSettings() }
            }
            // `-AutoCommands "n|look"` types commands, one every two seconds.
            if let list = UserDefaults.standard.string(forKey: "AutoCommands") {
                for (index, command) in list.split(separator: "|").enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(index) * 2) {
                        GameCoordinator.shared.insertCommand?(String(command), true)
                    }
                }
            }
            // `-ThenOpen "a|b"` opens more stories at ten-second intervals, to try switching.
            if let list = UserDefaults.standard.string(forKey: "ThenOpen") {
                for (index, name) in list.split(separator: "|").enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10 + Double(index) * 10) { [weak self] in
                        if let next = Library.shared.games.first(where: { $0.title.localizedCaseInsensitiveContains(name) }) { self?.open(next) }
                    }
                }
            }
            #endif
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSizeClassOverride()
    }

    // MARK: Layout

    @objc private func applyLayoutSettings() {
        let settings = Settings.shared
        primaryEdge = settings.sidePaneSide == .leading ? .leading : .trailing
        preferredPrimaryColumnWidthFraction = CGFloat(settings.sidePaneWidthFraction)
        minimumPrimaryColumnWidth = 240
        maximumPrimaryColumnWidth = 560

        switch settings.paneLayout {
        case .single:
            preferredDisplayMode = .secondaryOnly
        case .automatic, .alwaysDual:
            preferredDisplayMode = .oneBesideSecondary
        }
        lastWideOverride = nil
        updateSizeClassOverride()

        let theme = settings.theme
        overrideUserInterfaceStyle = theme.palette == .system ? .unspecified : (theme.colors(systemIsDark: false).isDark ? .dark : .light)
    }

    /// Decide whether the screen is wide enough for two panes even if the system calls it compact.
    private func updateSizeClassOverride() {
        let wide: Bool?
        switch Settings.shared.paneLayout {
        case .alwaysDual: wide = true
        case .single: wide = nil
        case .automatic: wide = view.bounds.width >= 560 ? true : nil
        }
        guard wide != lastWideOverride else { return }
        lastWideOverride = wide
        if wide == true {
            traitOverrides.horizontalSizeClass = .regular
        } else {
            traitOverrides.remove(UITraitHorizontalSizeClass.self)
        }
    }

    private func updateDetailItems() {
        guard let controller = detailNavigation.viewControllers.first as? GameViewController else { return }
        // The sidebar button only makes sense when the two panes are shown separately.
        controller.navigationItem.leftBarButtonItem = isCollapsed ? nil : displayModeButtonItem
        controller.navigationItem.leftItemsSupplementBackButton = true
    }

    func splitViewControllerDidCollapse(_ svc: UISplitViewController) { updateDetailItems() }
    func splitViewControllerDidExpand(_ svc: UISplitViewController) { updateDetailItems() }

    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        // With one pane, the library is where you start. A story already open stays.
        detailNavigation.viewControllers.first is GameViewController ? .secondary : .primary
    }

    // MARK: Opening

    func open(_ game: GameRecord) {
        guard game.format != .unsupported else { return }
        let controller = GameViewController(game: game)
        detailNavigation.setViewControllers([controller], animated: false)
        updateDetailItems()
        show(.secondary)
    }

    @objc private func restartRequested(_ note: Notification) {
        guard let game = note.object as? GameRecord else { return }
        // Give the old interpreter a moment to finish before starting again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.open(game) }
    }

    func importAndOpen(_ urls: [URL]) {
        var opened: GameRecord?
        var errors: [String] = []
        for url in urls {
            do { opened = try Library.shared.importGame(from: url) }
            catch { errors.append(error.localizedDescription) }
        }
        if let game = opened, urls.count == 1 { open(game) }
        if !errors.isEmpty {
            let alert = UIAlertController(title: "Could not add", message: errors.joined(separator: "\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    // MARK: Settings

    func showSettings() {
        let host = UIHostingController(rootView: SettingsView { [weak self] in self?.dismiss(animated: true) })
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }
}

/// Shown beside the library until a story is chosen.
final class PlaceholderViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "text.book.closed")
        config.text = "Choose a story"
        config.secondaryText = "Pick one from your library to begin, or add a new one."
        contentUnavailableConfiguration = config
        navigationItem.largeTitleDisplayMode = .never
    }
}
