import UIKit

/// What the game is waiting for, as far as the input bar is concerned.
enum GlkInputRequest: Equatable {
    case none
    /// Type a command; the window it goes to.
    case line(window: Int, initial: String)
    /// Press a key.
    case key(window: Int)
}

protocol GlkDisplayDelegate: AnyObject {
    func displayInputRequestChanged(_ display: GlkDisplay)
    func display(_ display: GlkDisplay, titleChanged title: String)
    func display(_ display: GlkDisplay, didAppendTextForVoiceOver text: String)
}

/// The area where Glk windows live. It applies what the session tells it to,
/// and turns taps into events.
final class GlkDisplay: UIView {
    weak var delegate: GlkDisplayDelegate?
    weak var session: GlkSession?

    private(set) var windowViews: [Int: GlkWindowView] = [:]
    private var styleSheet: GlkStyleSheet
    private var lineWindows: [Int: (initial: String, capacity: Int)] = [:]
    private var charWindows: Set<Int> = []
    private var terminators: [Int: [UInt32]] = [:]
    private var borderColor: UIColor?

    /// The space at the bottom taken by the input bar and keyboard.
    var bottomInset: CGFloat = 0 {
        didSet {
            for case let buffer as GlkBufferView in windowViews.values { buffer.bottomInset = insetFor(buffer) }
        }
    }

    var inputRequest: GlkInputRequest {
        // A line request wins over a key request, and a text buffer over a grid.
        if let id = lineWindows.keys.sorted(by: { rank($0) < rank($1) }).first, let entry = lineWindows[id] {
            return .line(window: id, initial: entry.initial)
        }
        if let id = charWindows.sorted(by: { rank($0) < rank($1) }).first { return .key(window: id) }
        return .none
    }

    var currentTerminators: [UInt32] {
        if case .line(let id, _) = inputRequest { return terminators[id] ?? [] }
        return []
    }

    var hasHyperlinkRequest: Bool {
        windowViews.values.contains { ($0 as? GlkBufferView)?.linkRequested == true || ($0 as? GlkGridView)?.linkRequested == true }
    }

    private func rank(_ id: Int) -> Int {
        windowViews[id]?.windowType == Int(wintype_TextBuffer) ? id : 100 + id
    }

    /// Called whenever the story text scrolls.
    var onScroll: (() -> Void)?

    init(styleSheet: GlkStyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        backgroundColor = styleSheet.colors.background
        clipsToBounds = true
        accessibilityElements = []
    }

    required init?(coder: NSCoder) { fatalError() }

    var primaryBuffer: GlkBufferView? {
        windowViews.keys.sorted().compactMap { windowViews[$0] as? GlkBufferView }.first
    }

    private func insetFor(_ view: GlkBufferView) -> CGFloat {
        // Only a window that reaches the bottom of the screen is covered by the bar.
        view.frame.maxY >= bounds.height - 2 ? bottomInset : 0
    }

    // MARK: Applying operations

    func apply(_ ops: [GlkUIOp]) {
        var touched = Set<Int>()
        let inputBefore = inputRequest
        var voiceOverText = ""

        for op in ops {
            switch op {
            case .newWindow(let id, let type, let hints):
                createWindow(id: id, type: type, hints: hints)

            case .deleteWindow(let id):
                if let view = windowViews.removeValue(forKey: id) { view.removeFromSuperview() }
                lineWindows.removeValue(forKey: id)
                charWindows.remove(id)
                updateAccessibilityElements()

            case .sizeWindow(let id, let rect):
                guard let view = windowViews[id] else { break }
                view.frame = rect
                view.frameDidChange()
                if let buffer = view as? GlkBufferView { buffer.bottomInset = insetFor(buffer) }

            case .print(let id, let text):
                touched.insert(id)
                if let buffer = windowViews[id] as? GlkBufferView {
                    buffer.append(text)
                    voiceOverText += text.string
                } else if let grid = windowViews[id] as? GlkGridView {
                    grid.print(text)
                }

            case .unprint(let id, let units):
                (windowViews[id] as? GlkBufferView)?.unprint(units: units)

            case .clear(let id):
                touched.insert(id)
                (windowViews[id] as? GlkBufferView)?.clear()
                (windowViews[id] as? GlkGridView)?.clear()
                (windowViews[id] as? GlkGraphicsView)?.clear()

            case .moveTo(let id, let column, let row):
                (windowViews[id] as? GlkGridView)?.moveTo(column: column, row: row)

            case .flowBreak:
                break

            case .fillRects(let id, let rects):
                (windowViews[id] as? GlkGraphicsView)?.fill(rects)

            case .drawImage(let id, let image, _, let x, let y, let width, let height, let rule, _, let run):
                if let graphics = windowViews[id] as? GlkGraphicsView {
                    graphics.draw(image: image, x: x, y: y, width: width, height: height, rule: rule)
                } else if let buffer = windowViews[id] as? GlkBufferView {
                    buffer.insertImage(image, alignment: x, width: width, height: height, rule: rule, run: run)
                    touched.insert(id)
                }

            case .setBackground(let id, let color):
                if id == -1 {
                    borderColor = color < 0 ? nil : GlkStyleSheet.color(UInt32(bitPattern: color))
                    backgroundColor = borderColor ?? styleSheet.colors.background
                } else if let graphics = windowViews[id] as? GlkGraphicsView {
                    graphics.setBackground(color)
                } else if let grid = windowViews[id] as? GlkGridView {
                    grid.overrideBackground = color < 0 ? nil : GlkStyleSheet.color(UInt32(bitPattern: color))
                    grid.setNeedsDisplay()
                }

            case .makeTransparent(let id):
                (windowViews[id] as? GlkGridView)?.makeTransparent()

            case .requestLine(let id, let initial, let capacity):
                lineWindows[id] = (initial, capacity)

            case .cancelLine(let id):
                lineWindows.removeValue(forKey: id)

            case .requestChar(let id): charWindows.insert(id)
            case .cancelChar(let id): charWindows.remove(id)

            case .requestMouse(let id):
                (windowViews[id] as? GlkGridView)?.mouseRequested = true
                (windowViews[id] as? GlkGraphicsView)?.mouseRequested = true
            case .cancelMouse(let id):
                (windowViews[id] as? GlkGridView)?.mouseRequested = false
                (windowViews[id] as? GlkGraphicsView)?.mouseRequested = false

            case .requestLink(let id):
                (windowViews[id] as? GlkBufferView)?.linkRequested = true
                (windowViews[id] as? GlkGridView)?.linkRequested = true
            case .cancelLink(let id):
                (windowViews[id] as? GlkBufferView)?.linkRequested = false
                (windowViews[id] as? GlkGridView)?.linkRequested = false

            case .setEcho(let id, let echo):
                (windowViews[id] as? GlkBufferView)?.setEcho(echo)

            case .setTerminators(let id, let keys):
                terminators[id] = keys

            case .setTitle(let title):
                delegate?.display(self, titleChanged: title)

            case .beep(let type):
                UIImpactFeedbackGenerator(style: type == 2 ? .medium : .light).impactOccurred()
            }
        }

        for view in windowViews.values { view.endBatch() }
        if inputRequest != inputBefore { delegate?.displayInputRequestChanged(self) }
        if !voiceOverText.isEmpty { delegate?.display(self, didAppendTextForVoiceOver: voiceOverText) }
    }

    private func createWindow(id: Int, type: Int, hints: GlkHintTable) {
        if windowViews[id] != nil { return }
        let view: GlkWindowView
        switch type {
        case Int(wintype_TextBuffer):
            let buffer = GlkBufferView(id: id, hints: hints, sheet: styleSheet)
            buffer.onLink = { [weak self] link in self?.session?.enqueue(.hyperlink(window: id, link: link)); buffer.linkRequested = false }
            buffer.onUserScroll = { }
            buffer.onScroll = { [weak self] in self?.onScroll?() }
            view = buffer
        case Int(wintype_TextGrid):
            let grid = GlkGridView(id: id, hints: hints, sheet: styleSheet)
            grid.onMouse = { [weak self] x, y in
                self?.session?.enqueue(.mouse(window: id, x: x, y: y)); grid.mouseRequested = false
            }
            grid.onLink = { [weak self] link in self?.session?.enqueue(.hyperlink(window: id, link: link)); grid.linkRequested = false }
            view = grid
        default:
            let graphics = GlkGraphicsView(id: id, hints: hints, sheet: styleSheet)
            graphics.onMouse = { [weak self] x, y in
                self?.session?.enqueue(.mouse(window: id, x: x, y: y)); graphics.mouseRequested = false
            }
            view = graphics
        }
        windowViews[id] = view
        addSubview(view)
        updateAccessibilityElements()
    }

    private func updateAccessibilityElements() {
        // Read the story first, then the status line.
        accessibilityElements = windowViews.values
            .sorted { ($0.windowType == Int(wintype_TextBuffer) ? 0 : 1, $0.windowID) < ($1.windowType == Int(wintype_TextBuffer) ? 0 : 1, $1.windowID) }
    }

    // MARK: Sending input

    /// Send what the player typed. Returns false if nobody was waiting for a line.
    @discardableResult
    func submitLine(_ text: String, terminator: UInt32 = 0) -> Bool {
        guard case .line(let id, _) = inputRequest else { return false }
        if let buffer = windowViews[id] as? GlkBufferView {
            buffer.echoInput(text)
            buffer.markTurnStart()
        }
        lineWindows.removeValue(forKey: id)
        session?.enqueue(.line(window: id, text: text, terminator: terminator))
        delegate?.displayInputRequestChanged(self)
        return true
    }

    @discardableResult
    func submitKey(_ code: UInt32) -> Bool {
        guard case .key(let id) = inputRequest else { return false }
        charWindows.remove(id)
        (windowViews[id] as? GlkBufferView)?.markTurnStart()
        session?.enqueue(.key(window: id, code: code))
        delegate?.displayInputRequestChanged(self)
        return true
    }

    /// A line the interpreter asked to cancel: forget the request.
    func cancelLineRequest(for id: Int) { lineWindows.removeValue(forKey: id) }

    // MARK: Style changes

    func apply(styleSheet sheet: GlkStyleSheet) {
        styleSheet = sheet
        backgroundColor = borderColor ?? sheet.colors.background
        for view in windowViews.values { view.applyStyleSheet(sheet) }
    }

    // MARK: Autosave

    struct Snapshot: Codable {
        struct Window: Codable {
            var id: Int
            var type: Int
            var rect: [Double]
            var hints: GlkHintTable
            var runs: [SnapshotRun]?
            var gridRows: [[SnapshotRun]]?
            var bitmap: Data?
            var echo: Bool?
        }
        var windows: [Window]
        var size: [Double]
    }

    func snapshot() -> Data? {
        var windows: [Snapshot.Window] = []
        for id in windowViews.keys.sorted() {
            guard let view = windowViews[id] else { continue }
            var item = Snapshot.Window(id: id, type: view.windowType,
                                       rect: [Double(view.frame.minX), Double(view.frame.minY), Double(view.frame.width), Double(view.frame.height)],
                                       hints: view.hints)
            if let buffer = view as? GlkBufferView {
                item.runs = SnapshotRun.runs(from: buffer.storage)
                item.echo = buffer.echo
            }
            if let grid = view as? GlkGridView { item.gridRows = grid.snapshot() }
            if let graphics = view as? GlkGraphicsView { item.bitmap = graphics.snapshot() }
            windows.append(item)
        }
        return try? JSONEncoder().encode(Snapshot(windows: windows, size: [Double(bounds.width), Double(bounds.height)]))
    }

    /// Put back what was on screen. Returns the windows, so the session knows they exist.
    func restore(from data: Data) -> [(id: Int, type: Int, hints: GlkHintTable, rect: CGRect)]? {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        var restored: [(Int, Int, GlkHintTable, CGRect)] = []
        for item in snapshot.windows {
            createWindow(id: item.id, type: item.type, hints: item.hints)
            guard let view = windowViews[item.id], item.rect.count == 4 else { continue }
            let rect = CGRect(x: item.rect[0], y: item.rect[1], width: item.rect[2], height: item.rect[3])
            view.frame = rect
            view.frameDidChange()
            if let buffer = view as? GlkBufferView, let runs = item.runs {
                let text = SnapshotRun.attributedString(from: runs, sheet: styleSheet, windowType: buffer.windowType, hints: buffer.hints)
                buffer.append(text)
                buffer.setEcho(item.echo ?? true)
            }
            if let grid = view as? GlkGridView, let rows = item.gridRows { grid.restore(rows) }
            if let graphics = view as? GlkGraphicsView, let bitmap = item.bitmap { graphics.restore(bitmap) }
            restored.append((item.id, item.type, item.hints, rect))
        }
        layoutIfNeeded()
        for view in windowViews.values { view.endBatch() }
        primaryBuffer?.scrollToBottom(animated: false)
        return restored
    }

    /// The text of the story, for the transcript.
    var storyText: String { primaryBuffer?.storage.string ?? "" }
}

