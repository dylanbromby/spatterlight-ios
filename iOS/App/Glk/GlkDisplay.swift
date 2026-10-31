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
    /// The windows moved, or a map appeared or went: the size to give the story may have changed.
    func displayLayoutDidChange(_ display: GlkDisplay)
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
            if oldValue != bottomInset, besideActive { relayoutWindows() }
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

    // MARK: Map layout
    //
    // A story may open a picture window above the text and draw a map in it. The interpreter lays
    // every window out itself, so to show the map somewhere else (hidden, or beside the story) we
    // keep the rectangles it asked for and place the views ourselves.

    /// The size the interpreter was last told the game area is.
    var toldSize: CGSize = .zero
    /// V6 Infocom games use full-screen graphics for borders; do not treat them as Glulx-style automaps.
    var automapLayoutEnabled = true { didSet { if oldValue != automapLayoutEnabled { mapHeightRatio = nil; layoutDidChange() } } }
    var mapPlacement: MapPlacement = .beside { didSet { if oldValue != mapPlacement { layoutDidChange() } } }
    /// Show the map as a small translucent panel over the story's top corner when held upright.
    var mapFloats = true { didSet { if oldValue != mapFloats { layoutDidChange() } } }
    var mapVisible = true { didSet { if oldValue != mapVisible { layoutDidChange() } } }
    private var terpRects: [Int: CGRect] = [:]
    /// How tall the map window comes out, as a fraction of the game area, measured from the interpreter.
    private var mapHeightRatio: CGFloat?

    /// The picture window across the width of the screen, above the story text, if the story has one.
    var mapWindowID: Int? {
        guard automapLayoutEnabled else { return nil }
        let referenceW = toldSize.width > 0 ? toldSize.width : bounds.width
        let referenceH = toldSize.height > 0 ? toldSize.height : bounds.height
        return windowViews.keys.sorted().first { id in
            isAutomapGraphicsWindow(id: id, referenceWidth: referenceW, referenceHeight: referenceH)
        }
    }

    private func isAutomapGraphicsWindow(id: Int, referenceWidth: CGFloat, referenceHeight: CGFloat) -> Bool {
        guard windowViews[id] is GlkGraphicsView, let rect = terpRects[id], referenceHeight > 0 else { return false }
        guard rect.width >= referenceWidth * 0.9, rect.height > 0 else { return false }
        let heightRatio = rect.height / referenceHeight
        // Full-screen V6 background windows are not automaps.
        if heightRatio >= 0.72 { return false }
        if heightRatio < 0.06 { return false }
        return true
    }

    var hasMap: Bool { mapWindowID != nil }

    private var besideActive: Bool {
        mapPlacement == .beside && mapVisible && hasMap && mapHeightRatio != nil && isWideLandscape
    }

    private var isWideLandscape: Bool {
        #if DEBUG
        // `-ForceBeside 12` pretends the screen is landscape for the first 12 seconds (for checking the layout).
        let seconds = UserDefaults.standard.double(forKey: "ForceBeside")
        if seconds > 0, ProcessInfo.processInfo.systemUptime - GlkDisplay.launchUptime < seconds { return true }
        #endif
        return bounds.width >= 600 && bounds.width > bounds.height * 1.15
    }

    /// The size to tell the interpreter. With the map beside the story, the story gets half the
    /// width, and the game area is made tall enough that the map window fills the other half.
    var terpSize: CGSize {
        if besideActive, let ratio = mapHeightRatio, ratio > 0.05 {
            // The map is as tall as what you can see, above the input bar and keyboard.
            let visible = max(200, bounds.height - bottomInset)
            return CGSize(width: (bounds.width / 2).rounded(.down), height: (visible / ratio).rounded())
        }
        return bounds.size
    }

    static let launchUptime = ProcessInfo.processInfo.systemUptime
    private var floatingActive: Bool {
        mapFloats && mapVisible && hasMap && !besideActive && bounds.width >= 600 && bounds.width <= bounds.height
    }

    private var layoutIsDirty = false

    private func layoutDidChange() {
        relayoutWindows()
        delegate?.displayLayoutDidChange(self)
    }

    /// Called when the device folds, rotates, or the split pane moves.
    func relayoutForBoundsChange() {
        relayoutWindows()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayoutWindows()
    }

    /// The map as a panel in the top right: a third of the width, translucent. The story draws the map
    /// around the room you are in, so the panel shows the middle of the map window at a reduced scale.
    private let mapPanelCornerRadius: CGFloat = 12
    private let mapBackdrop: CALayer = {
        let layer = CALayer()
        layer.cornerRadius = 12
        layer.masksToBounds = true
        return layer
    }()

    private func tintBackdrop(_ color: UIColor) {
        mapBackdrop.backgroundColor = color.withAlphaComponent(0.58).cgColor
    }

    private func placeFloatingMap(_ view: GlkWindowView, rect: CGRect) {
        // A tight crop around you: a few rooms, large enough to read the labels.
        let scale: CGFloat = 0.78
        let panelWidth = (bounds.width / 3).rounded()
        let panelHeight = (panelWidth * 0.82).rounded()
        let panel = CGRect(x: bounds.width - 8 - panelWidth, y: rect.minY + 6, width: panelWidth, height: panelHeight)
        let source = CGSize(width: panelWidth / scale, height: panelHeight / scale)
        view.bounds = CGRect(origin: .zero, size: rect.size)
        view.frameDidChange()
        view.center = CGPoint(x: panel.midX, y: panel.midY)
        view.transform = CGAffineTransform(scaleX: scale, y: scale)
        let visible = CGRect(x: (rect.width - source.width) / 2, y: (rect.height - source.height) / 2, width: source.width, height: source.height)
        let clip = CAShapeLayer()
        clip.path = UIBezierPath(roundedRect: visible, cornerRadius: mapPanelCornerRadius / scale).cgPath
        view.layer.mask = clip

        mapBackdrop.cornerRadius = mapPanelCornerRadius
        mapBackdrop.mask = nil
        if let graphics = view as? GlkGraphicsView { tintBackdrop(graphics.backdropColor) }
        mapBackdrop.frame = panel
        bringSubviewToFront(view)
        mapBackdrop.removeFromSuperlayer()
        layer.insertSublayer(mapBackdrop, below: view.layer)
    }

    private func relayoutWindows() {
        let mapID = mapWindowID
        let mapRect = mapID.flatMap { terpRects[$0] }
        let hideMap = !mapVisible && mapID != nil
        let beside = besideActive
        let floating = floatingActive
        let shiftUp = (hideMap || beside || floating) ? (mapRect?.height ?? 0) : 0
        let storyWidth = beside ? terpSize.width : bounds.width
        let xOffset: CGFloat = beside ? bounds.width - storyWidth : 0
        for (id, view) in windowViews {
            guard let rect = terpRects[id] else { continue }
            if id == mapID {
                view.isHidden = hideMap
                view.transform = .identity
                view.layer.mask = nil
                if !floating { mapBackdrop.removeFromSuperlayer() }
                (view as? GlkGraphicsView)?.floating = floating && mapRect != nil
                if floating, let mapRect = mapRect {
                    placeFloatingMap(view, rect: mapRect)
                } else if beside {
                    let pane = CGSize(width: xOffset, height: max(200, bounds.height - bottomInset))
                    let scale = min(1.5, min(pane.width / rect.width, pane.height / rect.height))
                    view.bounds = CGRect(origin: .zero, size: rect.size)
                    view.center = CGPoint(x: pane.width / 2, y: pane.height / 2)
                    view.frameDidChange()
                    view.transform = CGAffineTransform(scaleX: scale, y: scale)
                } else if view.frame != rect {
                    view.frame = rect
                    view.frameDidChange()
                }
                continue
            }
            var frame = rect
            frame.origin.x += xOffset
            if shiftUp > 0, let mapRect = mapRect, rect.minY >= mapRect.maxY - 1 {
                frame.origin.y -= shiftUp
                if rect.maxY >= (beside ? terpSize.height : toldSize.height) - 1 { frame.size.height = max(0, bounds.height - frame.origin.y) }
            }
            view.transform = .identity
            view.layer.mask = nil
            if view.frame != frame {
                view.frame = frame
                view.frameDidChange()
            }
            if let buffer = view as? GlkBufferView { buffer.bottomInset = insetFor(buffer) }
        }
        orderWindowViews()
    }

    /// Status grids and other overlays stay above story text and background graphics.
    private func orderWindowViews() {
        var graphics: [UIView] = []
        var buffers: [UIView] = []
        var grids: [UIView] = []
        for view in windowViews.values {
            switch view.windowType {
            case Int(wintype_TextBuffer): buffers.append(view)
            case Int(wintype_TextGrid): grids.append(view)
            default: graphics.append(view)
            }
        }
        for view in graphics { sendSubviewToBack(view) }
        for view in buffers { bringSubviewToFront(view) }
        for view in grids { bringSubviewToFront(view) }
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
        let bufferWasAtBottom = primaryBuffer?.isAtBottom ?? false
        var voiceOverText = ""

        for op in ops {
            switch op {
            case .newWindow(let id, let type, let hints):
                createWindow(id: id, type: type, hints: hints)

            case .deleteWindow(let id):
                if let view = windowViews.removeValue(forKey: id) { view.removeFromSuperview() }
                terpRects.removeValue(forKey: id)
                layoutIsDirty = true
                lineWindows.removeValue(forKey: id)
                charWindows.remove(id)
                updateAccessibilityElements()

            case .sizeWindow(let id, let rect):
                guard windowViews[id] != nil else { break }
                terpRects[id] = rect
                measureMapRatio(id: id, rect: rect)
                // Place the views now: drawing that follows in this batch must see the new size.
                relayoutWindows()
                layoutIsDirty = true

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
        if layoutIsDirty {
            layoutIsDirty = false
            relayoutWindows()
            // Windows moving or changing size must not leave the story scrolled away from its end.
            if bufferWasAtBottom { primaryBuffer?.scrollToBottom(animated: false) }
            delegate?.displayLayoutDidChange(self)
        }
        if mapBackdrop.superlayer != nil, let id = mapWindowID, let graphics = windowViews[id] as? GlkGraphicsView {
            tintBackdrop(graphics.backdropColor)
        }
        if inputRequest != inputBefore { delegate?.displayInputRequestChanged(self) }
        if !voiceOverText.isEmpty { delegate?.display(self, didAppendTextForVoiceOver: voiceOverText) }
    }

    private func measureMapRatio(id: Int, rect: CGRect) {
        guard automapLayoutEnabled, toldSize.height > 0,
              isAutomapGraphicsWindow(id: id, referenceWidth: toldSize.width, referenceHeight: toldSize.height) else { return }
        // Measured while the map is above the story; beside it, the ratio is already known.
        if mapHeightRatio == nil || !besideActive { mapHeightRatio = rect.height / toldSize.height }
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
                                       rect: { let r = terpRects[id] ?? view.frame; return [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }(),
                                       hints: view.hints)
            if let buffer = view as? GlkBufferView {
                item.runs = SnapshotRun.runs(from: buffer.storage)
                item.echo = buffer.echo
            }
            if let grid = view as? GlkGridView { item.gridRows = grid.snapshot() }
            if let graphics = view as? GlkGraphicsView { item.bitmap = graphics.snapshot() }
            windows.append(item)
        }
        return try? JSONEncoder().encode(Snapshot(windows: windows, size: [Double(toldSize.width), Double(toldSize.height)]))
    }

    /// Put back what was on screen. Returns the windows, so the session knows they exist.
    func restore(from data: Data) -> [(id: Int, type: Int, hints: GlkHintTable, rect: CGRect)]? {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        var restored: [(Int, Int, GlkHintTable, CGRect)] = []
        for item in snapshot.windows {
            createWindow(id: item.id, type: item.type, hints: item.hints)
            guard let view = windowViews[item.id], item.rect.count == 4 else { continue }
            let rect = CGRect(x: item.rect[0], y: item.rect[1], width: item.rect[2], height: item.rect[3])
            terpRects[item.id] = rect
            view.frame = rect
            view.frameDidChange()
            if view is GlkGraphicsView, rect.width >= CGFloat(snapshot.size.first ?? 0) * 0.9, snapshot.size.count == 2, snapshot.size[1] > 0, rect.height > 0 {
                mapHeightRatio = rect.height / CGFloat(snapshot.size[1])
            }
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
        relayoutWindows()
        delegate?.displayLayoutDidChange(self)
        return restored
    }

    /// The text of the story, for the transcript.
    var storyText: String { primaryBuffer?.storage.string ?? "" }
}

