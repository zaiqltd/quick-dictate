import AppKit
import Foundation
import Darwin

/// A proposal has no side effects. Only an explicit review in the UI should create
/// ReviewedLocalAction and pass it to the executor.
enum LocalAction: Equatable, Sendable {
    case shell(command: String, directory: URL)
    case openURL(URL)
    case openFile(URL)
    case openApplication(URL)

    var title: String {
        switch self {
        case .shell: return "Run terminal command"
        case .openURL: return "Open website"
        case .openFile: return "Open file"
        case .openApplication: return "Open application"
        }
    }

    var detail: String {
        switch self {
        case let .shell(command, directory): return "\(command)\n\nWorking folder: \(directory.path)"
        case let .openURL(url), let .openFile(url), let .openApplication(url): return url.absoluteString
        }
    }

    /// The work root comes from local settings, never from model arguments.
    static func proposal(toolName: String, arguments: [String: Any], workRoot: URL) throws -> LocalAction {
        let root = try validatedRoot(workRoot)
        func string(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.contains("\0") else { throw LocalActionError.invalid("The action needs a valid \(key).") }
            return value
        }
        func keys(_ allowed: Set<String>) throws {
            guard Set(arguments.keys).isSubset(of: allowed) else {
                throw LocalActionError.invalid("The action contains unsupported arguments.")
            }
        }
        let action: LocalAction
        switch toolName {
        case "run_terminal":
            try keys(["command", "directory"])
            let command = try string("command")
            let directory: String
            if let raw = arguments["directory"] as? String {
                directory = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : try string("directory")
            } else if arguments["directory"] == nil {
                directory = "."
            } else {
                throw LocalActionError.invalid("The action needs a valid directory.")
            }
            action = .shell(command: command, directory: pathURL(directory, relativeTo: root))
        case "open_url":
            try keys(["url"])
            guard let url = URL(string: try string("url")) else { throw LocalActionError.invalid("The website URL is invalid.") }
            action = .openURL(url)
        case "open_file":
            try keys(["path"])
            action = .openFile(pathURL(try string("path"), relativeTo: root))
        case "open_application":
            try keys(["path"])
            let path = try string("path")
            guard path.hasPrefix("/") else { throw LocalActionError.invalid("Choose an application's full path.") }
            action = .openApplication(URL(fileURLWithPath: path))
        default:
            throw LocalActionError.invalid("This action is not supported.")
        }
        return try action.validated(workRoot: root)
    }

    func validated(workRoot: URL) throws -> LocalAction {
        let root = try Self.validatedRoot(workRoot)
        switch self {
        case let .shell(command, directory):
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  command.utf8.count <= 16_384, !command.contains("\0") else {
                throw LocalActionError.invalid("Use a terminal command between 1 and 16,384 bytes.")
            }
            let folder = try Self.containedExistingPath(directory, root: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LocalActionError.invalid("The terminal working folder must be an existing directory.")
            }
            return .shell(command: command, directory: folder)
        case let .openURL(url):
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else {
                throw LocalActionError.invalid("Only HTTP or HTTPS website URLs without embedded credentials can be opened.")
            }
            return .openURL(url)
        case let .openFile(url):
            let file = try Self.containedExistingPath(url, root: root)
            let blockedComponents: Set<String> = [".credentials", ".codex", ".codex-secondary", ".ssh", ".aws", ".gnupg", "keychains"]
            let components = file.pathComponents.map { $0.lowercased() }
            let name = file.lastPathComponent.lowercased()
            guard !components.contains(where: { blockedComponents.contains($0) }),
                  name != ".env", !name.hasPrefix(".env."),
                  !["keychain", "keychain-db", "pem", "key"].contains(file.pathExtension.lowercased()) else {
                throw LocalActionError.invalid("Credential and private-key files cannot be opened through agent file actions.")
            }
            return .openFile(file)
        case let .openApplication(url):
            guard url.isFileURL, !url.path.contains("\0") else { throw LocalActionError.invalid("Choose an installed application.") }
            let app = url.standardizedFileURL.resolvingSymlinksInPath()
            let permitted = ["/Applications", "/System/Applications"].contains {
                Self.isContained(app, in: URL(fileURLWithPath: $0).resolvingSymlinksInPath())
            }
            var isDirectory: ObjCBool = false
            guard permitted, app.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LocalActionError.invalid("Choose an existing app in Applications or System Applications.")
            }
            return .openApplication(app)
        }
    }

    static func validatedRoot(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else { throw LocalActionError.invalid("Choose a local working folder.") }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalActionError.invalid("The chosen working folder does not exist or is not a directory.")
        }
        return root
    }

    private static func pathURL(_ path: String, relativeTo root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    private static func containedExistingPath(_ url: URL, root: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else { throw LocalActionError.invalid("Choose a local path inside the working folder.") }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(resolved, in: root) else { throw LocalActionError.invalid("The path is outside the chosen working folder.") }
        guard FileManager.default.fileExists(atPath: resolved.path) else { throw LocalActionError.invalid("The requested path does not exist.") }
        return resolved
    }

    private static func isContained(_ path: URL, in root: URL) -> Bool {
        let base = root.pathComponents
        return path.pathComponents.starts(with: base)
    }
}

struct ReviewedLocalAction: Sendable {
    let action: LocalAction
    let workRoot: URL

    /// Call only in response to the user's explicit Run / Open confirmation.
    init(action: LocalAction, workRoot: URL) throws {
        self.workRoot = try LocalAction.validatedRoot(workRoot)
        self.action = try action.validated(workRoot: self.workRoot)
    }
}

struct LocalActionResult: Sendable {
    let output: String
    let exitCode: Int32?
    let timedOut: Bool
    let cancelled: Bool
    let truncated: Bool

    var succeeded: Bool { !timedOut && !cancelled && (exitCode == nil || exitCode == 0) }
}

enum LocalActionError: LocalizedError {
    case invalid(String)
    case launchFailed
    case openFailed
    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case .launchFailed: return "The terminal command could not start. Check its working folder."
        case .openFailed: return "macOS could not open that item."
        }
    }
}

struct LocalActionExecutor: Sendable {
    /// Terminal commands run with the user's filesystem rights. The working folder
    /// is a starting location, NOT a sandbox. Output never goes to a model here.
    func run(_ reviewed: ReviewedLocalAction, timeout: TimeInterval = 30, outputLimit: Int = 64_000,
             onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> LocalActionResult {
        // Revalidate immediately before execution in case a path changed after review.
        let action = try reviewed.action.validated(workRoot: reviewed.workRoot)
        switch action {
        case let .shell(command, directory):
            let job = TerminalActionJob(command: command, directory: directory,
                                        timeout: min(max(timeout.isFinite ? timeout : 30, 0.05), 300),
                                        outputLimit: min(max(outputLimit, 256), 1_000_000), onOutput: onOutput)
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in job.start(continuation) }
            }, onCancel: { job.cancel() })
        case let .openURL(url), let .openFile(url):
            try Task.checkCancellation()
            let opened = try await MainActor.run {
                try Task.checkCancellation()
                return NSWorkspace.shared.open(url)
            }
            guard opened else { throw LocalActionError.openFailed }
            return LocalActionResult(output: "Opened \(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent).", exitCode: nil, timedOut: false, cancelled: false, truncated: false)
        case let .openApplication(url):
            try Task.checkCancellation()
            try await Self.openApplication(url)
            return LocalActionResult(output: "Opened \(url.deletingPathExtension().lastPathComponent).", exitCode: nil, timedOut: false, cancelled: false, truncated: false)
        }
    }

    @MainActor private static func openApplication(_ url: URL) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                if app != nil { continuation.resume() } else { continuation.resume(throwing: LocalActionError.openFailed) }
            }
        }
    }

    /// Deliberate allowlist: no API tokens, session/auth variables, shell startup
    /// files, SSH agent, or secondary-account Codex configuration are inherited.
    static func terminalEnvironment(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
         "HOME": home, "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "TERM": "dumb", "NO_COLOR": "1"]
    }
}

/// Owns a fresh process group. All bookkeeping, nonblocking reads, waitpid and
/// signals run off the main actor; the pipe keeps draining after the display cap.
/// Commands that intentionally daemonize can escape the group: review is the
/// permission boundary, not this lifetime management.
private final class TerminalActionJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.chad.quick-dictate.terminal", qos: .userInitiated)
    private let command: String
    private let directory: URL
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let onOutput: @Sendable (String) -> Void
    private var continuation: CheckedContinuation<LocalActionResult, Error>?
    private var timer: DispatchSourceTimer?
    private var pid: pid_t = 0
    private var readFD: Int32 = -1
    private var output = Data()
    private var truncated = false
    private var cancelled = false
    private var timedOut = false
    private var startedAt: TimeInterval = 0
    private var stoppingAt: TimeInterval?
    private var rootReaped = false
    private var exitCode: Int32?
    private var killSent = false
    private var completed = false

    init(command: String, directory: URL, timeout: TimeInterval, outputLimit: Int,
         onOutput: @escaping @Sendable (String) -> Void) {
        self.command = command; self.directory = directory; self.timeout = timeout
        self.outputLimit = outputLimit; self.onOutput = onOutput
    }

    func start(_ continuation: CheckedContinuation<LocalActionResult, Error>) {
        queue.async {
            self.continuation = continuation
            if self.cancelled { self.finish(); return }
            do { try self.spawn() }
            catch { self.completed = true; self.continuation = nil; continuation.resume(throwing: error); return }
            self.startedAt = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
            timer.setEventHandler { [self] in tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func cancel() {
        queue.async {
            guard !self.completed else { return }
            self.cancelled = true
            if self.pid > 0 { self.beginStopping() }
        }
    }

    private func spawn() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw LocalActionError.launchFailed }
        var keepReader = false
        defer {
            close(descriptors[1])
            if !keepReader { close(descriptors[0]) }
        }
        _ = fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK)
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw LocalActionError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw LocalActionError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        let chdirResult: Int32
        if #available(macOS 26.0, *) {
            chdirResult = posix_spawn_file_actions_addchdir(&actions, directory.path)
        } else {
            chdirResult = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }
        let setupResults = [
            chdirResult,
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, descriptors[0]),
            posix_spawn_file_actions_addclose(&actions, descriptors[1]),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        ]
        guard setupResults.allSatisfy({ $0 == 0 }) else { throw LocalActionError.launchFailed }
        let argumentStrings: [String] = ["/bin/zsh", "-f", "-c", command]
        let args: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { value in value.withCString { strdup($0) } } + [nil]
        let environmentStrings = LocalActionExecutor.terminalEnvironment().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let env: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in value.withCString { strdup($0) } } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        let result = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv.baseAddress!, environment.baseAddress!)
            }
        }
        guard result == 0, pid > 0 else { pid = 0; throw LocalActionError.launchFailed }
        readFD = descriptors[0]
        keepReader = true
    }

    private func tick() {
        guard !completed else { return }
        drain()
        if !rootReaped {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                rootReaped = true
                exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                // A finished shell must not leave a background child alive.
                beginStopping()
            } else if result == -1 && errno == ECHILD {
                rootReaped = true
                beginStopping()
            }
        }
        if rootReaped, kill(-pid, 0) == -1, errno == ESRCH {
            drain()
            finish()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if stoppingAt == nil && now - startedAt >= timeout {
            timedOut = true
            beginStopping()
        }
        if let stoppingAt, now - stoppingAt >= 0.2 {
            if !killSent { _ = kill(-pid, SIGKILL); killSent = true }
            if rootReaped && now - stoppingAt >= 0.24 { drain(); finish() }
        }
    }

    private func beginStopping() {
        guard stoppingAt == nil, pid > 0 else { return }
        stoppingAt = ProcessInfo.processInfo.systemUptime
        _ = kill(-pid, SIGTERM)
    }

    private func drain() {
        guard readFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8_192)
        // A command that floods stdout must not starve cancellation or timeout.
        for _ in 0..<64 {
            let count = read(readFD, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            let accepted = min(count, max(0, outputLimit - output.count))
            if accepted > 0 {
                let chunk = Data(bytes.prefix(accepted))
                output.append(chunk)
                onOutput(String(decoding: chunk, as: UTF8.self))
            }
            if accepted < count { truncated = true }
        }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if readFD >= 0 { close(readFD); readFD = -1 }
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: LocalActionResult(output: String(decoding: output, as: UTF8.self), exitCode: exitCode,
                                                         timedOut: timedOut, cancelled: cancelled, truncated: truncated))
    }
}
