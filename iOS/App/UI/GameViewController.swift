import UIKit
import UniformTypeIdentifiers

/// Shared between the story and the side pane: what is being played, and the
/// commands typed so far.
final class GameCoordinator {
    static let shared = GameCoordinator()

    private(set) var currentGame: GameRecord?
    private(set) var commandHistory: [String] = []

    /// Set by the story screen: put a command into the input bar.
    var insertCommand: ((String, Bool) -> Void)?

    func didStart(_ game: GameRecord) {
        currentGame = game
        commandHistory = []
        NotificationCenter.default.post(name: .coordinatorDidChange, object: self)
    }

    func didSend(_ command: String) {
        guard !command.isEmpty else { return }
        commandHistory.append(command)
        NotificationCenter.default.post(name: .coordinatorDidChange, object: self)
    }

    func didStop() {
        currentGame = nil
        commandHistory = []
        insertCommand = nil
        NotificationCenter.default.post(name: .coordinatorDidChange, object: self)
    }
}

extension Notification.Name {
    static let coordinatorDidChange = Notification.Name("SpatterlightCoordinatorDidChange")
}

/// Plays one game.
final class GameViewController: UIViewController, GlkSessionDelegate, GlkDisplayDelegate, UIDocumentPickerDelegate {
    let game: GameRecord
    private let display: GlkDisplay
    private let inputBar = InputBar()
    private var session: GlkSession?
    private var styleSheet: GlkStyleSheet
    private var started = false
    private var finished = false
    private var closing = false
    private var keyboardWanted = true
    private var pendingLine: String?
    private var history: [String] = []
    private var historyIndex = 0
    private var draft = ""
    private var timer: Timer?
    private var lastUISnapshot = Date.distantPast
    private var forceNextSnapshot = false
    private let scrollToBottomButton = UIButton(type: .system)
    private var inputBarBottom: NSLayoutConstraint!
    private var filePromptCompletion: ((String?) -> Void)?
    private var filePromptDestination: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(game: GameRecord) {
        self.game = game
        let settings = Settings.shared
        styleSheet = GameViewController.makeStyleSheet(settings: settings, traits: UITraitCollection.current)
        display = GlkDisplay(styleSheet: styleSheet)
        super.init(nibName: nil, bundle: nil)
        title = game.title
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    static func makeStyleSheet(settings: Settings, traits: UITraitCollection) -> GlkStyleSheet {
        GlkStyleSheet(theme: settings.theme, systemIsDark: traits.userInterfaceStyle == .dark,
                      contentSizeCategory: traits.preferredContentSizeCategory)
    }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = styleSheet.colors.background

        display.translatesAutoresizingMaskIntoConstraints = false
        display.delegate = self
        view.addSubview(display)

        inputBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputBar)

        var scrollConfig = UIButton.Configuration.filled()
        scrollConfig.image = UIImage(systemName: "arrow.down")
        scrollConfig.cornerStyle = .capsule
        scrollToBottomButton.configuration = scrollConfig
        scrollToBottomButton.accessibilityLabel = "Scroll to latest"
        scrollToBottomButton.alpha = 0
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        scrollToBottomButton.addAction(UIAction { [weak self] _ in self?.display.primaryBuffer?.scrollToBottom(animated: true) }, for: .touchUpInside)
        view.addSubview(scrollToBottomButton)
        display.onScroll = { [weak self] in self?.updateScrollButton() }

        NSLayoutConstraint.activate([
            display.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            display.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            display.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            display.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scrollToBottomButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            scrollToBottomButton.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -10),
        ])

        inputBar.onSubmitLine = { [weak self] text in self?.submitLine(text) }
        inputBar.onKey = { [weak self] code in self?.submitKey(code) }
        inputBar.onHistory = { [weak self] back in self?.stepHistory(back: back) }
        inputBar.onFocusChange = { [weak self] focused in
            guard let self = self, !self.closing else { return }
            if focused { self.keyboardWanted = true }
        }

        let hideKeyboardTap = UITapGestureRecognizer(target: self, action: #selector(storyTapped))
        hideKeyboardTap.cancelsTouchesInView = false
        hideKeyboardTap.delegate = self
        display.addGestureRecognizer(hideKeyboardTap)

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMenu()),
        ]

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contentSizeChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)

        GameCoordinator.shared.insertCommand = { [weak self] text, send in
            guard let self = self else { return }
            self.inputBar.field.text = text
            if send { self.inputBar.submit() } else { self.inputBar.focus() }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: GameViewController, _) in
            self.restyle()
        }
    }

    private func makeMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Share Transcript", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareTranscript() },
            UIAction(title: "Restart Story", image: UIImage(systemName: "arrow.counterclockwise"), attributes: .destructive) { [weak self] _ in self?.confirmRestart() },
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = max(0, view.bounds.maxY - inputBar.frame.minY)
        display.bottomInset = inset

        let size = display.bounds.size
        guard size.width > 10, size.height > 10 else { return }
        if !started {
            started = true
            startSession(size: size)
        } else {
            session?.gameAreaDidChange(size)
        }
        updateScrollButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if keyboardWanted { focusIfPossible() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { stopGame() }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { stopGame() }
    }

    // MARK: Starting

    private func startSession(size: CGSize) {
        guard let terp = game.format.terpName else { return }
        Library.shared.markPlayed(game)
        GameCoordinator.shared.didStart(game)

        var arguments: [String] = []
        if terp == "bocfel" {
            arguments += ["-n", "\(Settings.shared.zMachineTerp)", "-N", "a"]
        }
        arguments.append(game.fileURL.path)

        inputBar.setMode(.idle, showKeyRow: Settings.shared.showKeyRow, message: "Starting…")
        // A story that is still saving itself must finish before the next one looks for its autosave.
        GlkSession.whenIdle { [weak self] in
            guard let self = self, !self.closing else { return }
            self.launch(terp: terp, arguments: arguments, size: size)
        }
    }

    private func launch(terp: String, arguments: [String], size: CGSize) {
        let session = GlkSession(game: game, terpName: terp, arguments: arguments, theme: styleSheet,
                                 settings: Settings.shared, size: size)
        session.delegate = self
        display.session = session
        self.session = session

        // Bring back what was on screen if the game was autosaved.
        let wantsAutosave = Settings.shared.autosave
        if wantsAutosave, AutosaveStore.hasAutosave(for: game, terp: terp),
           let url = AutosaveStore.uiSnapshotURL(for: game, terp: terp),
           let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(GlkDisplay.Snapshot.self, from: data), !snapshot.windows.isEmpty {
            session.screenRestorer = { [weak self] in self?.display.restore(from: data) }
        } else {
            AutosaveStore.discard(for: game, terp: terp)
        }

        do {
            try session.start(environment: ["SPATTERLIGHT_AUTOSAVE_SIGNATURE": game.id])
        } catch {
            showAlert(title: "Could not start the story", message: error.localizedDescription)
        }
    }

    private func stopGame() {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        GameCoordinator.shared.didStop()
        guard let session = session else { return }
        if finished || session.isFinished { return }
        // Save the game and wait for the interpreter to finish, so the next
        // story can start straight away.
        forceNextSnapshot = true
        session.close(waitUntilStopped: false)
    }

    private func restartGame() {
        guard let terp = game.format.terpName else { return }
        session?.terminateWithoutSaving()
        AutosaveStore.discard(for: game, terp: terp)
        navigationController?.popViewController(animated: false)
        // The library opens the game again.
        NotificationCenter.default.post(name: .restartGameRequested, object: game)
    }

    private func confirmRestart() {
        let alert = UIAlertController(title: "Restart this story?", message: "Your progress will be lost unless you have saved.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Restart", style: .destructive) { [weak self] _ in self?.restartGame() })
        present(alert, animated: true)
    }

    // MARK: Input

    private func submitLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.submitLine(trimmed) {
            noteCommand(trimmed)
        } else {
            // The story is busy; send it when it asks.
            pendingLine = trimmed
            inputBar.field.text = ""
            inputBar.field.placeholder = "Queued: \(trimmed)"
        }
    }

    private func noteCommand(_ text: String) {
        if !text.isEmpty, history.last != text { history.append(text) }
        historyIndex = history.count
        draft = ""
        GameCoordinator.shared.didSend(text)
        if Settings.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5) }
    }

    private func submitKey(_ code: UInt32) {
        display.submitKey(code)
        if Settings.shared.haptics { UISelectionFeedbackGenerator().selectionChanged() }
    }

    private func stepHistory(back: Bool) -> String? {
        if historyIndex == history.count { draft = inputBar.text }
        if back {
            guard historyIndex > 0 else { return nil }
            historyIndex -= 1
            return history[historyIndex]
        }
        guard historyIndex < history.count else { return nil }
        historyIndex += 1
        return historyIndex == history.count ? draft : history[historyIndex]
    }

    func displayInputRequestChanged(_ display: GlkDisplay) {
        let show = Settings.shared.showKeyRow
        switch display.inputRequest {
        case .line(_, let initial):
            inputBar.setMode(.line, showKeyRow: show, initialText: initial)
            if let queued = pendingLine {
                pendingLine = nil
                inputBar.field.text = queued
                inputBar.submit()
            }
        case .key:
            inputBar.setMode(.key, showKeyRow: show)
        case .none:
            if finished {
                inputBar.setMode(.finished, showKeyRow: show, message: "The story has ended.")
            } else {
                inputBar.setMode(.idle, showKeyRow: show, message: pendingLine.map { "Queued: \($0)" })
            }
        }
        if keyboardWanted && !finished { focusIfPossible() }
        updateScrollButton()
    }

    private func focusIfPossible() {
        guard view.window != nil, !inputBar.field.isFirstResponder, inputBar.mode != .finished else { return }
        inputBar.focus()
    }

    @objc private func storyTapped() {
        // Tapping the story puts the keyboard away so you can read.
        if inputBar.field.isFirstResponder {
            keyboardWanted = false
            inputBar.field.resignFirstResponder()
        }
    }

    // MARK: Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        func command(_ input: String, _ action: Selector, modifiers: UIKeyModifierFlags = []) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            command(UIKeyCommand.inputUpArrow, #selector(arrowUp)),
            command(UIKeyCommand.inputDownArrow, #selector(arrowDown)),
            command(UIKeyCommand.inputLeftArrow, #selector(arrowLeft)),
            command(UIKeyCommand.inputRightArrow, #selector(arrowRight)),
            command(UIKeyCommand.inputEscape, #selector(escapeKey)),
            command(UIKeyCommand.inputPageUp, #selector(pageUp)),
            command(UIKeyCommand.inputPageDown, #selector(pageDown)),
        ]
    }

    @objc private func arrowUp() {
        if inputBar.mode == .key { submitKey(UInt32(keycode_Up)) } else if let text = stepHistory(back: true) { inputBar.field.text = text }
    }
    @objc private func arrowDown() {
        if inputBar.mode == .key { submitKey(UInt32(keycode_Down)) } else if let text = stepHistory(back: false) { inputBar.field.text = text }
    }
    @objc private func arrowLeft() { if inputBar.mode == .key { submitKey(UInt32(keycode_Left)) } else { moveCursor(-1) } }
    @objc private func arrowRight() { if inputBar.mode == .key { submitKey(UInt32(keycode_Right)) } else { moveCursor(1) } }
    @objc private func escapeKey() { if inputBar.mode == .key { submitKey(UInt32(keycode_Escape)) } }
    @objc private func pageUp() { scrollStory(by: -1) }
    @objc private func pageDown() { scrollStory(by: 1) }

    private func moveCursor(_ delta: Int) {
        let field = inputBar.field
        guard let range = field.selectedTextRange,
              let target = field.position(from: range.start, offset: delta) else { return }
        field.selectedTextRange = field.textRange(from: target, to: target)
    }

    private func scrollStory(by pages: Int) {
        guard let text = display.primaryBuffer?.textView else { return }
        let page = text.bounds.height * 0.85
        let y = min(max(-text.adjustedContentInset.top, text.contentOffset.y + CGFloat(pages) * page),
                    text.contentSize.height - text.bounds.height + text.contentInset.bottom)
        text.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    // MARK: Scroll button

    private func updateScrollButton() {
        guard let buffer = display.primaryBuffer else { return }
        let show = !buffer.isAtBottom
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
            self.scrollToBottomButton.alpha = show ? 1 : 0
        }
    }

    // MARK: Style

    @objc private func settingsChanged() { restyle() }
    @objc private func contentSizeChanged() { restyle() }

    private func restyle() {
        styleSheet = GameViewController.makeStyleSheet(settings: Settings.shared, traits: traitCollection)
        view.backgroundColor = styleSheet.colors.background
        display.apply(styleSheet: styleSheet)
        session?.updateStyleSheet(styleSheet)
        // The interpreter sizes its windows from the font size, so tell it.
        session?.gameAreaDidChange(display.bounds.size, force: true)
        navigationController?.navigationBar.overrideUserInterfaceStyle = styleSheet.colors.isDark ? .dark : .light
        overrideUserInterfaceStyle = Settings.shared.theme.palette == .system ? .unspecified : (styleSheet.colors.isDark ? .dark : .light)
    }

    // MARK: Lifecycle

    @objc private func appDidEnterBackground() {
        guard let session = session, !finished, !closing else { return }
        // iOS may end the app while it is in the background: save now.
        forceNextSnapshot = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Autosave") { [weak self] in
            self?.endBackgroundTask()
        }
        session.enqueue(.autosave)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: GlkSessionDelegate

    func session(_ session: GlkSession, apply ops: [GlkUIOp]) {
        display.apply(ops)
    }

    func sessionDidFinish(_ session: GlkSession, status: Int32) {
        timer?.invalidate()
        finished = true
        guard !closing else { return }
        // The story ended on its own: nothing to come back to.
        if let terp = game.format.terpName {
            AutosaveStore.discard(for: game, terp: terp)
        }
        inputBar.setMode(.finished, showKeyRow: false, message: status == 0 ? "The story has ended." : "The story stopped unexpectedly.")
        inputBar.field.resignFirstResponder()
        if status == 0 {
            UIAccessibility.post(notification: .announcement, argument: "The story has ended.")
        }
    }

    func session(_ session: GlkSession, showError message: String) {
        showAlert(title: "Story error", message: message)
    }

    func session(_ session: GlkSession, setTimer interval: TimeInterval) {
        timer?.invalidate()
        timer = nil
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.05), repeats: true) { [weak session] _ in
            guard let session = session, session.isWaitingForEvent else { return }
            session.enqueue(.timer)
        }
    }

    func session(_ session: GlkSession, currentInputFor window: Int) -> String { inputBar.text }

    func sessionRequestsRestart(_ session: GlkSession) { restartGame() }

    func sessionSnapshotForAutosave(_ session: GlkSession) -> Data? {
        let now = Date()
        if !forceNextSnapshot && now.timeIntervalSince(lastUISnapshot) < 8 { return nil }
        forceNextSnapshot = false
        lastUISnapshot = now
        return display.snapshot()
    }

    // MARK: Files

    func session(_ session: GlkSession, promptForFile usage: Int, save: Bool, completion: @escaping (String?) -> Void) {
        let kind = usage & 0xff
        let ext: String
        switch UInt32(kind) {
        case UInt32(fileusage_SavedGame): ext = "glksave"
        case UInt32(fileusage_Transcript): ext = "txt"
        case UInt32(fileusage_InputRecord): ext = "rec"
        default: ext = "glkdata"
        }
        let directory = game.savesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        inputBar.field.resignFirstResponder()
        if save {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            let alert = UIAlertController(title: kind == Int(fileusage_SavedGame) ? "Save Game" : "Save File",
                                          message: nil, preferredStyle: .alert)
            alert.addTextField { field in
                field.text = "\(self.game.title) \(formatter.string(from: Date()))"
                field.clearButtonMode = .whileEditing
                field.autocapitalizationType = .sentences
                field.accessibilityLabel = "File name"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
            alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
                var name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
                name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
                if name.isEmpty { name = self.game.title }
                completion(directory.appendingPathComponent(name).appendingPathExtension(ext).path)
            })
            present(alert, animated: true)
        } else {
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == ext }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }
            let sheet = UIAlertController(title: kind == Int(fileusage_SavedGame) ? "Restore Game" : "Open File",
                                          message: files.isEmpty ? "There are no saved files for this story yet." : nil,
                                          preferredStyle: .actionSheet)
            for file in files.prefix(12) {
                sheet.addAction(UIAlertAction(title: file.deletingPathExtension().lastPathComponent, style: .default) { _ in
                    completion(file.path)
                })
            }
            sheet.addAction(UIAlertAction(title: "Import from Files…", style: .default) { [weak self] _ in
                self?.pickFile(completion: completion, destination: directory)
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
            sheet.popoverPresentationController?.sourceView = inputBar
            sheet.popoverPresentationController?.sourceRect = inputBar.bounds
            present(sheet, animated: true)
        }
    }

    private func pickFile(completion: @escaping (String?) -> Void, destination: URL) {
        filePromptCompletion = completion
        filePromptDestination = destination
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let destination = filePromptDestination else { filePromptCompletion?(nil); return }
        let target = destination.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
        filePromptCompletion?(target.path)
        filePromptCompletion = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        filePromptCompletion?(nil)
        filePromptCompletion = nil
    }

    // MARK: GlkDisplayDelegate

    func display(_ display: GlkDisplay, titleChanged title: String) {}

    func display(_ display: GlkDisplay, didAppendTextForVoiceOver text: String) {
        guard UIAccessibility.isVoiceOverRunning, Settings.shared.announceText else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: String(trimmed.prefix(1500)))
    }

    // MARK: Menu actions

    private func shareTranscript() {
        let text = display.storyText
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(game.title) transcript.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(controller, animated: true)
    }

    private func showAlert(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension GameViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension Notification.Name {
    static let restartGameRequested = Notification.Name("SpatterlightRestartGameRequested")
}
