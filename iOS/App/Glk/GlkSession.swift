import UIKit

/// What the interpreter asked the screen to do. The session turns the
/// interpreter's requests into these and hands them to the main thread in
/// batches; `GlkDisplay` applies them to the views.
enum GlkUIOp {
    case newWindow(id: Int, type: Int, hints: GlkHintTable)
    case deleteWindow(id: Int)
    case sizeWindow(id: Int, rect: CGRect)
    case print(id: Int, text: NSAttributedString)
    case unprint(id: Int, units: Int)
    case clear(id: Int)
    case moveTo(id: Int, column: Int, row: Int)
    case flowBreak(id: Int)
    case fillRects(id: Int, rects: [(color: UInt32, rect: CGRect)])
    case drawImage(id: Int, image: UIImage, resource: Int, x: Int, y: Int, width: Int, height: Int, rule: UInt32, maxWidth: UInt32, run: GlkRun)
    case setBackground(id: Int, color: Int32)
    case makeTransparent(id: Int)
    case requestLine(id: Int, initial: String, capacity: Int)
    case cancelLine(id: Int)
    case requestChar(id: Int)
    case cancelChar(id: Int)
    case requestMouse(id: Int)
    case cancelMouse(id: Int)
    case requestLink(id: Int)
    case cancelLink(id: Int)
    case setEcho(id: Int, echo: Bool)
    case setTerminators(id: Int, keys: [UInt32])
    case setTitle(String)
    case beep(type: Int)
}

/// An event to give the interpreter when it asks for one.
struct GlkEvent {
    var type: Int32
    var window: Int32 = 0
    var value1: Int32 = 0
    var value2: Int32 = 0
    var value4: Int32 = 0
    var value5: Int32 = 0
    var payload = Data()

    static func key(window: Int, code: UInt32) -> GlkEvent {
        GlkEvent(type: Int32(EVTKEY), window: Int32(window), value1: Int32(bitPattern: code))
    }

    static func line(window: Int, text: String, terminator: UInt32 = 0) -> GlkEvent {
        let units = Array(text.utf16)
        var data = Data()
        units.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress)?.assumingMemoryBound(to: UInt8.self), count: units.count * 2)) }
        return GlkEvent(type: Int32(EVTLINE), window: Int32(window), value1: Int32(units.count),
                        value2: Int32(bitPattern: terminator), payload: data)
    }

    static func mouse(window: Int, x: Int, y: Int) -> GlkEvent {
        GlkEvent(type: Int32(EVTMOUSE), window: Int32(window), value1: Int32(x), value2: Int32(y))
    }

    static func hyperlink(window: Int, link: Int) -> GlkEvent {
        GlkEvent(type: Int32(EVTHYPER), window: Int32(window), value1: Int32(link))
    }

    static var timer: GlkEvent { GlkEvent(type: Int32(EVTTIMER)) }
    static var redraw: GlkEvent { GlkEvent(type: Int32(EVTREDRAW)) }
    static var quit: GlkEvent { GlkEvent(type: Int32(EVTQUIT)) }
    static var autosave: GlkEvent { GlkEvent(type: Int32(EVTAUTOSAVE)) }
}

protocol GlkSessionDelegate: AnyObject {
    /// All called on the main thread.
    func session(_ session: GlkSession, apply ops: [GlkUIOp])
    func sessionDidFinish(_ session: GlkSession, status: Int32)
    func session(_ session: GlkSession, showError message: String)
    func session(_ session: GlkSession, promptForFile usage: Int, save: Bool, completion: @escaping (String?) -> Void)
    func session(_ session: GlkSession, setTimer interval: TimeInterval)
    func session(_ session: GlkSession, currentInputFor window: Int) -> String
    func sessionRequestsRestart(_ session: GlkSession)
    func sessionSnapshotForAutosave(_ session: GlkSession) -> Data?
}

/// One running game: the interpreter, and the conversation with it.
///
/// The interpreter asks for things over a pipe (print this, open a window, wait
/// for an event). A thread of ours, the bridge, reads those requests. Most of
/// them become `GlkUIOp`s for the main thread; a few need an answer, which the
/// bridge works out from what it knows. When the interpreter waits for an event,
/// the bridge sleeps until the main thread has one.
final class GlkSession {
    weak var delegate: GlkSessionDelegate?

    let game: GameRecord
    let terpName: String
    let arguments: [String]

    // MARK: State shared between threads

    private let eventLock = NSCondition()
    private var events: [GlkEvent] = []
    private var terpWaiting = false
    private var closing = false
    private(set) var isFinished = false

    private let styleLock = NSLock()
    private var _styleSheet: GlkStyleSheet
    private var _settings: Settings
    private var gameSize: CGSize

    var styleSheet: GlkStyleSheet {
        styleLock.lock(); defer { styleLock.unlock() }
        return _styleSheet
    }

    /// True while the interpreter is waiting for an event from us.
    var isWaitingForEvent: Bool {
        eventLock.lock(); defer { eventLock.unlock() }
        return terpWaiting
    }

    // MARK: State of the bridge thread

    private final class WindowInfo {
        let id: Int
        let type: Int
        var rect: CGRect = .zero
        var hints: GlkHintTable
        var zForeground: UInt32?
        var zBackground: UInt32?
        var reverse = false
        var link = 0
        var tail: [UInt16] = []
        init(id: Int, type: Int, hints: GlkHintTable) { self.id = id; self.type = type; self.hints = hints }
    }

    private var windows: [Int: WindowInfo] = [:]
    private var bufferHints = GlkHintTable()
    private var gridHints = GlkHintTable()
    private var pendingOps: [GlkUIOp] = []
    private var images: [Int: UIImage] = [:]
    private var lastImage: UIImage?
    private var process: TerpProcess?
    private var bridgeThread: Thread?
    private var fileBuffer = UnsafeMutableRawPointer.allocate(byteCount: Int(GLKBUFSIZE) + 1, alignment: 16)
    /// Set when the game was autosaved: puts the screen back (main thread).
    var screenRestorer: (() -> [(id: Int, type: Int, hints: GlkHintTable, rect: CGRect)]?)?
    private var eventCount = 0
    static let debug = UserDefaults.standard.bool(forKey: "DebugGlk")
    private var startedAt = Date()

    init(game: GameRecord, terpName: String, arguments: [String], theme: GlkStyleSheet, settings: Settings, size: CGSize) {
        self.game = game
        self.terpName = terpName
        self.arguments = arguments
        self._styleSheet = theme
        self._settings = settings
        self.gameSize = size
    }

    deinit {
        fileBuffer.deallocate()
    }

    // MARK: Starting and stopping

    /// Tell the session about windows brought back from an autosave: the
    /// interpreter will not create them again.
    func restoreWindows(_ list: [(id: Int, type: Int, hints: GlkHintTable, rect: CGRect)]) {
        for item in list {
            let info = WindowInfo(id: item.id, type: item.type, hints: item.hints)
            info.rect = item.rect
            windows[item.id] = info
        }
    }

    /// Only one interpreter runs at a time. Main thread only.
    private static var active: GlkSession?
    private static var waiters: [() -> Void] = []

    /// Runs the block once no session is running (immediately, if none is).
    static func whenIdle(_ block: @escaping () -> Void) {
        if active == nil { block() } else { waiters.append(block) }
    }

    private static func didFinish(_ session: GlkSession) {
        guard active === session else { return }
        active = nil
        let pending = waiters
        waiters.removeAll()
        for block in pending { block() }
    }

    func start(environment: [String: String]) throws {
        let library = try TerpLibrary.library(named: terpName)
        let process = try TerpProcess(library: library, arguments: arguments, environment: environment)
        self.process = process
        GlkSession.active = self

        // The interpreter expects its preferences first, then the window size.
        enqueue(prefsEvent())
        enqueue(arrangeEvent(force: true))

        let bridge = Thread { [weak self] in self?.bridgeLoop() }
        bridge.name = "Glk bridge (\(game.title))"
        bridge.stackSize = 4 * 1024 * 1024
        bridge.qualityOfService = .userInitiated
        bridgeThread = bridge
        bridge.start()
    }

    /// Ask the interpreter to stop. It autosaves first if autosave is on.
    func close(waitUntilStopped: Bool) {
        eventLock.lock()
        closing = true
        eventLock.unlock()
        if !isFinished {
            enqueue(.autosave)
            enqueue(.quit)
            // Wake the bridge if it is waiting on us.
            eventLock.lock(); eventLock.broadcast(); eventLock.unlock()
        }
        if waitUntilStopped { process?.waitUntilFinished() }
    }

    /// Stop the game without saving anything.
    func terminateWithoutSaving() {
        eventLock.lock()
        closing = true
        events.removeAll()
        eventLock.unlock()
        enqueue(.quit)
        process?.waitUntilFinished()
    }

    // MARK: Events from the UI (main thread)

    func enqueue(_ event: GlkEvent) {
        eventLock.lock()
        events.append(event)
        eventLock.broadcast()
        eventLock.unlock()
    }

    func updateStyleSheet(_ sheet: GlkStyleSheet) {
        styleLock.lock()
        _styleSheet = sheet
        styleLock.unlock()
    }

    func gameAreaDidChange(_ size: CGSize, force: Bool = false) {
        styleLock.lock()
        let changed = size != gameSize
        gameSize = size
        styleLock.unlock()
        if changed || force { enqueue(arrangeEvent(force: force)) }
    }

    private func prefsEvent() -> GlkEvent {
        GlkEvent(type: Int32(EVTPREFS), window: 0, value1: _settings.showGraphics ? 1 : 0, value2: 0,
                 value4: _settings.autosave ? 1 : 0, value5: 0)
    }

    private func arrangeEvent(force: Bool) -> GlkEvent {
        styleLock.lock()
        let sheet = _styleSheet
        let size = gameSize
        styleLock.unlock()

        var s = settings_struct()
        s.screen_width = Int32(size.width.rounded())
        s.screen_height = Int32(size.height.rounded())
        // The Glk library adds 5 points for the text system's own padding; ours has none.
        let margin = Int32(sheet.theme.margin)
        s.buffer_margin_x = max(0, margin - 5)
        s.buffer_margin_y = 0
        s.grid_margin_x = max(0, margin - 5)
        s.grid_margin_y = 0
        s.cell_width = Float(sheet.gridCellSize.width)
        s.cell_height = Float(sheet.gridCellSize.height)
        s.buffer_cell_width = Float(sheet.bufferCellSize.width)
        s.buffer_cell_height = Float(sheet.bufferCellSize.height)
        s.buffer_foreground = Int32(bitPattern: GlkStyleSheet.integer(sheet.colors.text))
        s.buffer_background = Int32(bitPattern: GlkStyleSheet.integer(sheet.colors.background))
        s.grid_foreground = Int32(bitPattern: GlkStyleSheet.integer(sheet.colors.gridText))
        s.grid_background = Int32(bitPattern: GlkStyleSheet.integer(sheet.colors.gridBackground))
        s.do_styles = 1
        s.quote_boxes = 0
        s.determinism = 0
        s.error_handling = 0
        s.sa_delays = 0
        s.sa_display_style = 0
        s.sa_inventory = 0
        s.sa_palette = 0
        s.slowdraw = 0
        s.flicker = 0
        s.zmachine_terp = Int32(_settings.zMachineTerp)
        s.z6_graphics = 0
        s.z6_colorize = 0
        s.zmachine_no_err_win = 0
        s.comprehend_graphics = 0
        s.voiceover_on = UIAccessibility.isVoiceOverRunning ? 1 : 0
        s.force_arrange = force ? 1 : 0

        let data = withUnsafeBytes(of: &s) { Data($0) }
        return GlkEvent(type: Int32(EVTARRANGE), window: 0, value1: s.screen_width, value2: s.screen_height, payload: data)
    }

    // MARK: Bridge thread

    private func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = read(fd, buffer + done, count - done)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            done += n
        }
        return true
    }

    private func writeFully(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = write(fd, buffer + done, count - done)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            done += n
        }
        return true
    }

    private func bridgeLoop() {
        guard let process = process else { return }
        var big: UnsafeMutableRawPointer?
        defer { big?.deallocate() }

        while true {
            var request = message()
            guard readFully(process.requestFD, &request, MemoryLayout<message>.size) else { break }

            var payload = fileBuffer
            if request.len > Int(GLKBUFSIZE) {
                big?.deallocate()
                big = UnsafeMutableRawPointer.allocate(byteCount: request.len + 1, alignment: 16)
                payload = big!
            }
            if request.len > 0 {
                guard readFully(process.requestFD, payload, request.len) else { break }
            }
            payload.storeBytes(of: 0, toByteOffset: request.len, as: UInt8.self)

            if GlkSession.debug { NSLog("glk[%@] cmd=%d a1=%d a2=%d len=%d", game.title, request.cmd, request.a1, request.a2, request.len) }
            var reply = message()
            var replyPayload: (UnsafeRawPointer, Int)?
            let keepGoing = autoreleasepool { handle(request, payload: payload, reply: &reply, replyPayload: &replyPayload) }
            if !keepGoing { break }

            if reply.cmd > Int32(NOREPLY) {
                var header = reply
                var ok = writeFully(process.eventFD, &header, MemoryLayout<message>.size)
                if ok, let (pointer, length) = replyPayload, length > 0 { ok = writeFully(process.eventFD, pointer, length) }
                if !ok { break }
            }
        }

        // The interpreter has closed its end, or we have been told to stop.
        flush()
        // If the interpreter is still waiting for us, let it see end of file.
        Darwin.close(process.eventFD)
        process.waitUntilFinished()
        let status = process.exitStatus
        if GlkSession.debug { NSLog("glk[%@] finished, status %d", game.title, status) }
        Darwin.close(process.requestFD)
        eventLock.lock()
        isFinished = true
        eventLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            GlkSession.didFinish(self)
            self.delegate?.sessionDidFinish(self, status: status)
        }
    }

    private func flush() {
        guard !pendingOps.isEmpty else { return }
        let batch = coalesce(pendingOps)
        pendingOps.removeAll(keepingCapacity: true)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.session(self, apply: batch)
        }
    }

    /// Merge runs of print operations on the same window, so the text view sees
    /// one append instead of hundreds.
    private func coalesce(_ ops: [GlkUIOp]) -> [GlkUIOp] {
        var result: [GlkUIOp] = []
        result.reserveCapacity(ops.count)
        var accumulating: (id: Int, text: NSMutableAttributedString)?

        func finishAccumulating() {
            if let acc = accumulating {
                result.append(.print(id: acc.id, text: acc.text))
                accumulating = nil
            }
        }

        for op in ops {
            if case .print(let id, let text) = op {
                if let acc = accumulating, acc.id == id {
                    acc.text.append(text)
                } else {
                    finishAccumulating()
                    accumulating = (id, NSMutableAttributedString(attributedString: text))
                }
            } else {
                finishAccumulating()
                result.append(op)
            }
        }
        finishAccumulating()
        return result
    }

    private func post(_ op: GlkUIOp) {
        pendingOps.append(op)
        if pendingOps.count > 400 { flush() }
    }

    private var eventScratch: [UInt8] = []

    /// Returns false when the bridge should stop.
    private func handle(_ req: message, payload: UnsafeMutableRawPointer, reply: inout message, replyPayload: inout (UnsafeRawPointer, Int)?) -> Bool {
        var window = windows[Int(req.a1)]
        var justRestored = false
        switch Int(req.cmd) {
        case NEXTEVENT:
            // An autorestored game can go straight to waiting for input, never drawing anything.
            _ = restoreScreenIfNeeded()
        case PRINT, UNPRINT, INITLINE, INITCHAR, INITMOUSE, INITLINK:
            if restoreScreenIfNeeded() {
                justRestored = true
                window = windows[Int(req.a1)]
            }
        default:
            break
        }

        switch Int(req.cmd) {
        case HELLO:
            reply.cmd = Int32(OKAY)
            reply.a1 = _settings.showGraphics ? 1 : 0
            reply.a2 = 0

        case NEXTEVENT:
            flush()
            eventCount += 1
            eventLock.lock()
            while events.isEmpty && req.a1 != 0 && !closing {
                terpWaiting = true
                eventLock.wait()
            }
            terpWaiting = false
            let next: GlkEvent? = events.isEmpty ? nil : events.removeFirst()
            eventLock.unlock()

            if let event = next {
                eventScratch = [UInt8](event.payload)
                reply.cmd = event.type
                reply.a1 = event.window
                reply.a2 = event.value1
                reply.a3 = event.value2
                reply.a4 = event.value4
                reply.a5 = event.value5
                reply.len = eventScratch.count
                if !eventScratch.isEmpty {
                    eventScratch.withUnsafeBufferPointer { replyPayload = (UnsafeRawPointer($0.baseAddress!), $0.count) }
                }
            } else if req.a1 == 0 {
                reply.cmd = Int32(OKAY)
            } else {
                // We were told to close while the interpreter waited.
                return false
            }

        case PROMPTOPEN, PROMPTSAVE:
            flush()
            let semaphore = DispatchSemaphore(value: 0)
            var chosen: String?
            let save = Int(req.cmd) == PROMPTSAVE
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let delegate = self.delegate else { semaphore.signal(); return }
                delegate.session(self, promptForFile: Int(req.a1), save: save) { path in
                    chosen = path
                    semaphore.signal()
                }
            }
            semaphore.wait()
            reply.cmd = Int32(OKAY)
            if let path = chosen, let cString = path.cString(using: .utf8), cString.count > 1 {
                let length = cString.count - 1
                eventScratch = cString.dropLast().map { UInt8(bitPattern: $0) }
                reply.len = length
                eventScratch.withUnsafeBufferPointer { replyPayload = (UnsafeRawPointer($0.baseAddress!), $0.count) }
            }

        case STYLEHINT:
            setHint(windowType: Int(req.a1), style: Int(req.a2), hint: Int(req.a3), value: req.a4)

        case CLEARHINT:
            setHint(windowType: Int(req.a1), style: Int(req.a2), hint: Int(req.a3), value: nil)

        case STYLEMEASURE:
            reply.cmd = Int32(OKAY)
            if let window = window, let value = styleSheet.measure(windowType: window.type, style: Int(req.a2), hint: Int(req.a3), hints: window.hints) {
                reply.a1 = 1
                reply.a2 = value
            }

        case NEWWIN:
            reply.cmd = Int32(OKAY)
            reply.a1 = Int32(newWindow(type: Int(req.a1), expected: Int(req.a2)))

        case DELWIN:
            if windows.removeValue(forKey: Int(req.a1)) != nil { post(.deleteWindow(id: Int(req.a1))) }

        case NEWCHAN, FINDSOUND:
            reply.cmd = Int32(OKAY)

        case DELCHAN, LOADSOUND, SETVOLUME, PLAYSOUND, STOPSOUND, PAUSE, UNPAUSE, EVTSOUND, EVTVOLUME:
            break

        case FINDIMAGE:
            reply.cmd = Int32(OKAY)
            if let image = images[Int(req.a1)] {
                lastImage = image
                reply.a1 = 1
            }

        case LOADIMAGE:
            let path = String(cString: payload.assumingMemoryBound(to: CChar.self))
            loadImage(resource: Int(req.a1), path: path, offset: Int(req.a2), length: Int(req.a3))

        case SIZEIMAGE:
            reply.cmd = Int32(OKAY)
            if let image = lastImage, let cg = image.cgImage {
                reply.a1 = Int32(cg.width)
                reply.a2 = Int32(cg.height)
            }

        case PURGEIMG:
            images.removeValue(forKey: Int(req.a1))

        case BEEP:
            post(.beep(type: Int(req.a1)))

        case SHOWERROR:
            let text = String(cString: payload.assumingMemoryBound(to: CChar.self))
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.session(self, showError: text)
            }

        case CANPRINT:
            reply.cmd = Int32(OKAY)
            let ch = UInt32(bitPattern: req.a1)
            reply.a1 = (ch >= 0x20 && ch != 0x7f && !(ch >= 0x80 && ch < 0xa0) && ch <= 0x10ffff) ? 1 : 0

        case SIZWIN:
            guard let window = window else { break }
            var size = sizewinrect()
            memcpy(&size, payload, min(MemoryLayout<sizewinrect>.size, req.len))
            // A layout worked out for a window size we no longer have.
            styleLock.lock(); let current = gameSize; styleLock.unlock()
            if abs(CGFloat(size.gamewidth) - current.width) > 1.5 || abs(CGFloat(size.gameheight) - current.height) > 1.5 { break }
            let rect = CGRect(x: CGFloat(size.x0), y: CGFloat(size.y0),
                              width: max(0, CGFloat(size.x1 - size.x0)), height: max(0, CGFloat(size.y1 - size.y0)))
            window.rect = rect
            post(.sizeWindow(id: window.id, rect: rect))

        case CLRWIN:
            if let window = window {
                window.tail.removeAll()
                post(.clear(id: window.id))
            }

        case SETBGND:
            post(.setBackground(id: Int(req.a1), color: req.a2))

        case DRAWIMAGE:
            guard let window = window, let image = lastImage else { break }
            var draw = drawrect()
            memcpy(&draw, payload, min(MemoryLayout<drawrect>.size, req.len))
            let run = GlkRun(style: Int(style_Normal), foreground: nil, background: nil, reverse: false)
            post(.drawImage(id: window.id, image: image, resource: -1, x: Int(draw.x), y: Int(draw.y),
                            width: Int(draw.width), height: Int(draw.height), rule: draw.imagerule, maxWidth: draw.maxwidth, run: run))

        case FILLRECT:
            guard window != nil else { break }
            let count = min(Int(req.a2), req.len / MemoryLayout<fillrect>.size)
            var rects: [(UInt32, CGRect)] = []
            rects.reserveCapacity(count)
            for i in 0..<count {
                var r = fillrect()
                memcpy(&r, payload + i * MemoryLayout<fillrect>.size, MemoryLayout<fillrect>.size)
                rects.append((r.color, CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h))))
            }
            post(.fillRects(id: Int(req.a1), rects: rects))

        case PRINT:
            guard let window = window, req.len >= 2 else { break }
            let count = req.len / 2
            let units = Array(UnsafeBufferPointer(start: payload.assumingMemoryBound(to: UInt16.self), count: count))
            print(units, style: Int(req.a2), to: window)

        case UNPRINT:
            reply.cmd = Int32(OKAY)
            if let window = window, req.len >= 2 {
                let count = req.len / 2
                let units = Array(UnsafeBufferPointer(start: payload.assumingMemoryBound(to: UInt16.self), count: count))
                if window.tail.count >= units.count && Array(window.tail.suffix(units.count)) == units {
                    window.tail.removeLast(units.count)
                    post(.unprint(id: window.id, units: units.count))
                    reply.a1 = 1
                }
            }

        case MOVETO:
            post(.moveTo(id: Int(req.a1), column: Int(req.a2), row: Int(req.a3)))

        case SETECHO:
            post(.setEcho(id: Int(req.a1), echo: req.a2 != 0))

        case TERMINATORS:
            let count = min(Int(req.a2), req.len / 4)
            let keys = Array(UnsafeBufferPointer(start: payload.assumingMemoryBound(to: UInt32.self), count: count))
            post(.setTerminators(id: Int(req.a1), keys: keys))

        case FLOWBREAK:
            post(.flowBreak(id: Int(req.a1)))

        case SETZCOLOR:
            if let window = window {
                window.zForeground = applyZColor(UInt32(bitPattern: req.a2), current: window.zForeground)
                window.zBackground = applyZColor(UInt32(bitPattern: req.a3), current: window.zBackground)
            }

        case SETREVERSE:
            window?.reverse = req.a2 != 0

        case QUOTEBOX:
            break

        case INITLINE:
            let count = req.len / 2
            let units = Array(UnsafeBufferPointer(start: payload.assumingMemoryBound(to: UInt16.self), count: count))
            // After a restore the window already holds what was being typed.
            let initial = justRestored ? "" : String(decoding: units, as: UTF16.self)
            post(.requestLine(id: Int(req.a1), initial: initial, capacity: Int(req.a2)))

        case CANCELLINE:
            // The interpreter wants what has been typed so far. Ask the main
            // thread: this is rare, so waiting for it is fine.
            flush()
            var typed = ""
            DispatchQueue.main.sync { [weak self] in
                guard let self = self, let delegate = self.delegate else { return }
                typed = delegate.session(self, currentInputFor: Int(req.a1))
            }
            post(.cancelLine(id: Int(req.a1)))
            flush()
            reply.cmd = Int32(OKAY)
            let units = Array(typed.utf16.prefix(Int(req.a2)))
            eventScratch = units.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
            reply.len = eventScratch.count
            if !eventScratch.isEmpty {
                eventScratch.withUnsafeBufferPointer { replyPayload = (UnsafeRawPointer($0.baseAddress!), $0.count) }
            }

        case INITCHAR: post(.requestChar(id: Int(req.a1)))
        case CANCELCHAR: post(.cancelChar(id: Int(req.a1)))
        case INITMOUSE: post(.requestMouse(id: Int(req.a1)))
        case CANCELMOUSE: post(.cancelMouse(id: Int(req.a1)))
        case SETLINK: window?.link = Int(req.a2)
        case INITLINK: post(.requestLink(id: Int(req.a1)))
        case CANCELLINK: post(.cancelLink(id: Int(req.a1)))

        case TIMER:
            let interval = TimeInterval(req.a1) / 1000
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.session(self, setTimer: interval)
            }

        case MAKETRANSPARENT:
            post(.makeTransparent(id: Int(req.a1)))

        case SETTITLE:
            post(.setTitle(String(cString: payload.assumingMemoryBound(to: CChar.self))))

        case AUTOSAVE:
            flush()
            // Save what is on screen, now that the interpreter has saved its state.
            DispatchQueue.main.sync { [weak self] in
                guard let self = self else { return }
                self.writeUISnapshot(self.delegate?.sessionSnapshotForAutosave(self))
            }

        case RESET:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.sessionRequestsRestart(self)
            }

        case BANNERCOLS, BANNERLINES:
            reply.cmd = Int32(OKAY)
            if let window = window {
                let sheet = styleSheet
                let margin = sheet.theme.margin
                if Int(req.cmd) == BANNERCOLS {
                    reply.a1 = Int32(max(0, (window.rect.width - 2 * margin) / sheet.bufferCellSize.width))
                } else {
                    reply.a1 = Int32(max(0, window.rect.height / sheet.bufferCellSize.height))
                }
            }

        case REFRESH, MENUITEM:
            break

        default:
            break
        }
        return true
    }

    // MARK: Helpers for the bridge

    /// Brings back the autosaved screen. Like the macOS app, this waits until the interpreter,
    /// having restored its own state, first uses a window it believes already exists.
    private func restoreScreenIfNeeded() -> Bool {
        guard let restorer = screenRestorer, windows.isEmpty else { return false }
        screenRestorer = nil
        flush()
        var list: [(id: Int, type: Int, hints: GlkHintTable, rect: CGRect)]?
        DispatchQueue.main.sync { list = restorer() }
        guard let restored = list, !restored.isEmpty else { return false }
        restoreWindows(restored)
        restoreInputRequests()
        // The player may have changed settings since: have the interpreter send the window sizes again.
        enqueue(arrangeEvent(force: true))
        return true
    }

    /// Glulxe does not ask for input again after restoring: the request travels in the archived
    /// windows (autosave.plist, an NSKeyedArchiver file). Read it back so the input bar knows
    /// what the story is waiting for.
    private func restoreInputRequests() {
        guard let url = AutosaveStore.directory(for: game, terp: terpName)?.appendingPathComponent("autosave.plist"),
              let data = try? Data(contentsOf: url),
              let archive = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any] else { return }
        func flag(_ dict: [String: Any], _ key: String) -> Bool { ((dict[key] as? NSNumber)?.intValue ?? 0) != 0 }
        for case let dict as [String: Any] in objects {
            guard let peer = (dict["peer"] as? NSNumber)?.intValue, windows[peer] != nil else { continue }
            if flag(dict, "line_request") {
                post(.requestLine(id: peer, initial: "", capacity: (dict["cap"] as? NSNumber)?.intValue ?? 256))
            }
            if flag(dict, "char_request") { post(.requestChar(id: peer)) }
            if flag(dict, "mouse_request") { post(.requestMouse(id: peer)) }
            if flag(dict, "hyper_request") { post(.requestLink(id: peer)) }
        }
    }

    private func setHint(windowType: Int, style: Int, hint: Int, value: Int32?) {
        if windowType == Int(wintype_AllTypes) || windowType == Int(wintype_TextGrid) { gridHints[style, hint] = value }
        if windowType == Int(wintype_AllTypes) || windowType == Int(wintype_TextBuffer) { bufferHints[style, hint] = value }
    }

    private func newWindow(type: Int, expected: Int) -> Int {
        guard type == Int(wintype_TextBuffer) || type == Int(wintype_TextGrid) || type == Int(wintype_Graphics) else { return -1 }
        // A window the interpreter restored from an autosave already exists.
        if windows[expected] != nil { return expected }
        var id = expected
        if id < 0 || id >= 64 || windows[id] != nil {
            id = (0..<64).first { windows[$0] == nil } ?? -1
        }
        if id < 0 { return -1 }
        let hints = type == Int(wintype_TextGrid) ? gridHints : bufferHints
        windows[id] = WindowInfo(id: id, type: type, hints: hints)
        post(.newWindow(id: id, type: type, hints: hints))
        return id
    }

    private func applyZColor(_ value: UInt32, current: UInt32?) -> UInt32? {
        switch value {
        case zcolor_Current: return current
        case zcolor_Default, zcolor_Transparent, zcolor_Cursor: return nil
        default: return value & 0xffffff
        }
    }

    private func print(_ units: [UInt16], style: Int, to window: WindowInfo) {
        let sheet = styleSheet
        let run = GlkRun(style: style, foreground: window.zForeground, background: window.zBackground, reverse: window.reverse)
        let string = String(decoding: units, as: UTF16.self)
        let attributes = sheet.attributes(for: run, windowType: window.type, hints: window.hints, link: window.link)
        post(.print(id: window.id, text: NSAttributedString(string: string, attributes: attributes)))
        window.tail.append(contentsOf: units)
        if window.tail.count > 512 { window.tail.removeFirst(window.tail.count - 256) }
    }

    private func loadImage(resource: Int, path: String, offset: Int, length: Int) {
        guard _settings.showGraphics, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: length), let image = UIImage(data: data) else { return }
            images[resource] = image
            lastImage = image
        } catch {
            NSLog("Could not read image %d: %@", resource, "\(error)")
        }
    }

    // MARK: Autosave of the screen

    private func writeUISnapshot(_ data: Data?) {
        guard let url = AutosaveStore.uiSnapshotURL(for: game, terp: terpName) else { return }
        guard let data = data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
