import Foundation

/// An interpreter built as a framework and loaded into this process.
///
/// iOS cannot spawn the interpreters as processes the way the macOS app does, so
/// each one is a framework carrying its own copy of the Glk library. Running a
/// game is calling `sp_terp_run` on a thread; the interpreter talks to the app
/// over a pair of pipes, using the same protocol as on macOS.
final class TerpLibrary {
    typealias RunFunction = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, Int32, Int32) -> Int32
    typealias ResetFunction = @convention(c) () -> Void

    enum LoadError: Error, LocalizedError {
        case missing(String)
        case dlopen(String)
        var errorDescription: String? {
            switch self {
            case .missing(let name): return "The \(name) interpreter is not part of this build."
            case .dlopen(let message): return message
            }
        }
    }

    let name: String
    private let handle: UnsafeMutableRawPointer
    private let runFunction: RunFunction
    private let resetFunction: ResetFunction
    private var hasRun = false

    private static var loaded: [String: TerpLibrary] = [:]
    private static let lock = NSLock()

    /// Interpreters stay loaded for the life of the app: they cannot be unloaded.
    static func library(named name: String) throws -> TerpLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let library = loaded[name] { return library }
        let library = try TerpLibrary(name: name)
        loaded[name] = library
        return library
    }

    private init(name: String) throws {
        self.name = name
        guard let frameworks = Bundle.main.privateFrameworksPath else { throw LoadError.missing(name) }
        let path = "\(frameworks)/\(name).framework/\(name)"
        guard FileManager.default.fileExists(atPath: path) else { throw LoadError.missing(name) }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError.dlopen(String(cString: dlerror()))
        }
        guard let run = dlsym(handle, "sp_terp_run"), let reset = dlsym(handle, "sp_terp_reset_state") else {
            throw LoadError.dlopen("\(name) does not export the interpreter entry points.")
        }
        self.handle = handle
        self.runFunction = unsafeBitCast(run, to: RunFunction.self)
        self.resetFunction = unsafeBitCast(reset, to: ResetFunction.self)
    }

    /// Runs the interpreter on the calling thread until the game ends.
    /// Only one game can run at a time; the caller must make sure of that.
    func run(arguments: [String], readFD: Int32, writeFD: Int32) -> Int32 {
        if hasRun {
            // A second game: put the interpreter back as it was when loaded.
            resetFunction()
        }
        hasRun = true

        var cArguments: [UnsafeMutablePointer<CChar>?] = ([name] + arguments).map { strdup($0) }
        cArguments.append(nil)
        defer { cArguments.forEach { free($0) } }
        return cArguments.withUnsafeMutableBufferPointer { buffer in
            runFunction(Int32(buffer.count - 1), buffer.baseAddress, readFD, writeFD)
        }
    }
}

/// A running interpreter: the thread, and our ends of the two pipes.
final class TerpProcess {
    /// We read what the interpreter requests from this.
    let requestFD: Int32
    /// We write events to this.
    let eventFD: Int32

    private let finished = DispatchSemaphore(value: 0)
    private(set) var exitStatus: Int32 = 0

    /// Only one interpreter may run at a time (they share this process).
    private static let running = DispatchSemaphore(value: 1)

    init(library: TerpLibrary, arguments: [String], environment: [String: String]) throws {
        var toTerp: [Int32] = [0, 0]    // events: [read, write]
        var fromTerp: [Int32] = [0, 0]  // requests: [read, write]
        guard pipe(&toTerp) == 0, pipe(&fromTerp) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        requestFD = fromTerp[0]
        eventFD = toTerp[1]
        let terpRead = toTerp[0]
        let terpWrite = fromTerp[1]

        // Writing to a pipe whose reader has gone must be an error, not a signal.
        signal(SIGPIPE, SIG_IGN)

        let runner = Thread { [unowned self] in
            TerpProcess.running.wait()
            for (key, value) in environment { setenv(key, value, 1) }
            self.exitStatus = library.run(arguments: arguments, readFD: terpRead, writeFD: terpWrite)
            TerpProcess.running.signal()
            self.finished.signal()
        }
        runner.name = "Interpreter (\(library.name))"
        runner.stackSize = 32 * 1024 * 1024
        runner.qualityOfService = .userInitiated
        runner.start()
    }

    /// Blocks until the interpreter thread has returned.
    func waitUntilFinished() {
        finished.wait()
        finished.signal()
    }

    func closeFDs() {
        close(requestFD)
        close(eventFD)
    }
}
