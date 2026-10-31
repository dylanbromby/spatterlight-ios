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
    private var lastPaneLayout: PaneLayout?

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

    private var didChooseFirstColumn = false

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Starting on a narrow screen, the library is the first thing to see, not the empty story pane.
        guard !didChooseFirstColumn else { return }
        didChooseFirstColumn = true
        if isCollapsed, !(detailNavigation.viewControllers.first is GameViewController) {
            show(.primary)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        paintWindow()
        // `-OpenGame <title>` on the command line opens a story at launch (handy for testing).
        if let title = UserDefaults.standard.string(forKey: "OpenGame"),
           let game = Library.shared.games.last(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
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
        updateColumnWidth()
        updateSplitBehavior()
    }

    private var isPortrait: Bool { view.bounds.width < view.bounds.height }

    /// In portrait (an unfolded Duo held upright) the side pane floats over the story rather than
    /// squeezing it, so the story, and any map above it, keep the full width.
    private func updateSplitBehavior() {
        let behavior: UISplitViewController.SplitBehavior =
            (Settings.shared.paneLayout == .automatic && isPortrait) ? .overlay : .tile
        if preferredSplitBehavior != behavior { preferredSplitBehavior = behavior }
    }

    /// In portrait the window is narrow, so the side pane gets a bigger share of it.
    private func updateColumnWidth() {
        let base = CGFloat(Settings.shared.sidePaneWidthFraction)
        let portrait = view.bounds.width < view.bounds.height
        let fraction = portrait ? max(base, 0.55) : base
        if preferredPrimaryColumnWidthFraction != fraction { preferredPrimaryColumnWidthFraction = fraction }
    }

    // MARK: Layout

    @objc private func applyLayoutSettings() {
        let settings = Settings.shared
        primaryEdge = settings.sidePaneSide == .leading ? .leading : .trailing
        updateColumnWidth()
        minimumPrimaryColumnWidth = 240
        maximumPrimaryColumnWidth = 560

        // Only when the choice itself changes, so other settings do not bring a hidden side pane back.
        if settings.paneLayout != lastPaneLayout {
            lastPaneLayout = settings.paneLayout
            switch settings.paneLayout {
            case .single:
                preferredDisplayMode = .secondaryOnly
            case .automatic, .alwaysDual:
                preferredDisplayMode = .oneBesideSecondary
            }
        }
        lastWideOverride = nil
        updateSizeClassOverride()

        let theme = settings.theme
        overrideUserInterfaceStyle = theme.palette == .system ? .unspecified : (theme.colors(systemIsDark: false).isDark ? .dark : .light)
        paintWindow()
    }

    /// Anything the panes do not cover, such as the edge beside a cutout, takes the page colour.
    private func paintWindow() {
        let colors = Settings.shared.theme.colors(systemIsDark: traitCollection.userInterfaceStyle == .dark)
        view.window?.backgroundColor = colors.background
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
        // The system supplies the sidebar button (and the back button when collapsed); adding
        // our own displayModeButtonItem as well left a second, empty-looking button.
        guard let controller = detailNavigation.viewControllers.first as? GameViewController else { return }
        controller.navigationItem.leftBarButtonItem = nil
        controller.navigationItem.leftItemsSupplementBackButton = false
        controller.onStoryTapped = { [weak self] in self?.storyTapped() }
    }

    /// Tapping the story puts the sidebar away if it is showing.
    private func storyTapped() {
        guard !isCollapsed, displayMode != .secondaryOnly else { return }
        hide(.primary)
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
        if !isCollapsed, isPortrait, Settings.shared.paneLayout == .automatic { hide(.primary) }
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
