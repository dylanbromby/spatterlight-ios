import UIKit

/// A scratchpad for the story being played, kept with the game.
final class NotesViewController: UIViewController, UITextViewDelegate {
    private let textView = UITextView()
    private let placeholder = UILabel()
    private var game: GameRecord?
    private var saveWork: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = self
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.accessibilityLabel = "Notes"
        view.addSubview(textView)

        placeholder.text = "Notes for this story: puzzles, maps, codes…"
        placeholder.textColor = .placeholderText
        placeholder.font = UIFont.preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.numberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 17),
            placeholder.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -17),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(gameChanged), name: .coordinatorDidChange, object: nil)
        gameChanged()
    }

    private func notesURL(for game: GameRecord) -> URL { game.directoryURL.appendingPathComponent("notes.txt") }

    @objc private func gameChanged() {
        let newGame = GameCoordinator.shared.currentGame
        if newGame?.id != game?.id {
            saveNow()
            game = newGame
            if let game = game, let text = try? String(contentsOf: notesURL(for: game), encoding: .utf8) {
                textView.text = text
            } else {
                textView.text = ""
            }
        }
        textView.isEditable = game != nil
        placeholder.text = game == nil ? "Open a story to keep notes on it." : "Notes for this story: puzzles, maps, codes…"
        placeholder.isHidden = !textView.text.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveNow() {
        guard let game = game else { return }
        try? textView.text.write(to: notesURL(for: game), atomically: true, encoding: .utf8)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }
}

/// The commands typed in this session. Tap one to bring it back.
final class HistoryViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .coordinatorDidChange, object: nil)
        tableView.accessibilityLabel = "Command history"
    }

    private var commands: [String] { GameCoordinator.shared.commandHistory.reversed() }

    @objc private func reload() {
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        if commands.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "clock.arrow.circlepath")
            config.text = "No commands yet"
            config.secondaryText = "What you type in the story shows up here."
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        commands.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = commands[indexPath.row]
        content.textProperties.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        GameCoordinator.shared.insertCommand?(commands[indexPath.row], false)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let send = UIContextualAction(style: .normal, title: "Send") { [weak self] _, _, done in
            guard let self = self else { return done(false) }
            GameCoordinator.shared.insertCommand?(self.commands[indexPath.row], true)
            done(true)
        }
        send.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [send])
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        commands.isEmpty ? nil : "Tap to reuse, swipe to send"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }
}

/// The side pane: the library, notes, or command history, whichever is chosen.
final class SidePaneViewController: UIViewController {
    var onOpenGame: ((GameRecord) -> Void)?
    var onSettings: (() -> Void)?
    private var current: UIViewController?
    private let library = LibraryViewController()
    private lazy var notes = NotesViewController()
    private lazy var history = HistoryViewController(style: .insetGrouped)
    private let picker = UISegmentedControl()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        library.embedded = true
        library.onOpen = { [weak self] game in self?.onOpenGame?(game) }

        for (index, content) in SidePaneContent.allCases.enumerated() {
            picker.insertSegment(withTitle: content.title, at: index, animated: false)
        }
        picker.addTarget(self, action: #selector(pickerChanged), for: .valueChanged)
        picker.accessibilityLabel = "Side pane"
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            picker.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        title = "Spatterlight"

        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settingsTapped))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Settings"
        let add = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(addTapped))
        add.accessibilityLabel = "Add story"
        navigationItem.rightBarButtonItem = add

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        show(Settings.shared.sidePane)
    }

    @objc private func settingsTapped() { onSettings?() }

    @objc private func addTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = library
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    @objc private func pickerChanged() {
        let content = SidePaneContent.allCases[picker.selectedSegmentIndex]
        if Settings.shared.sidePane != content { Settings.shared.sidePane = content }
    }

    @objc private func settingsChanged() {
        show(Settings.shared.sidePane)
    }

    private func show(_ content: SidePaneContent) {
        picker.selectedSegmentIndex = SidePaneContent.allCases.firstIndex(of: content) ?? 0
        let next: UIViewController
        switch content {
        case .library: next = library
        case .notes: next = notes
        case .history: next = history
        }
        guard next !== current else { return }
        current?.willMove(toParent: nil)
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        next.didMove(toParent: self)
        current = next
    }
}
