import Foundation
import Darwin

enum CodexRunEvent: Equatable, Sendable {
    case started
    case thinking
    case message(String)
    case commandStarted(String)
    case commandFinished(command: String, output: String, exitCode: Int?)
    case filesChanged([String])
    case toolStarted(String)
    case toolFinished(String)
    case status(String)
    case completed
}

struct CodexRunResult: Equatable, Sendable {
    let finalText: String
    let exitCode: Int32
    let truncated: Bool
}

@MainActor protocol CodexRunning {
    func run(prompt: String, workingDirectory: URL, screenControl: Bool,
             onEvent: @escaping @MainActor (CodexRunEvent) -> Void) async throws -> CodexRunResult
}

enum CodexCLIError: LocalizedError {
    case unavailable
    case invalidPrompt
    case invalidDirectory
    case launchFailed
    case timeout
    case failed(String)
    case incomplete

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex CLI was not found. Install Codex CLI and sign in to your primary account."
        case .invalidPrompt: return "Give Full Control a request between 1 and 65,536 bytes."
        case .invalidDirectory: return "Choose an existing local folder for Full Control."
        case .launchFailed: return "Codex CLI could not start. Check its installation and chosen folder."
        case .timeout: return "Codex reached its 30-minute time limit. Its running commands were stopped."
        case let .failed(detail): return "Codex could not complete the request. \(detail)"
        case .incomplete: return "Codex stopped before returning a complete answer. Check the activity and try again."
        }
    }
}

/// Full Control is deliberately a separate, explicitly enabled mode. It invokes
/// the user's primary Codex CLI with the bypass requested by the user. The
/// working folder is a starting directory, not a filesystem sandbox.
@MainActor final class CodexCLI: CodexRunning {
    static let model = "gpt-6-astra"
    static let reasoningEffort = "medium"
    private let executable: URL?
    private let homeDirectory: URL
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let inheritedEnvironment: [String: String]

    init(executable: URL? = nil,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         timeout: TimeInterval = 1_800, outputLimit: Int = 262_144,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.homeDirectory = homeDirectory
        self.timeout = min(max(timeout.isFinite ? timeout : 1_800, 0.05), 86_400)
        self.outputLimit = min(max(outputLimit, 256), 1_048_576)
        self.inheritedEnvironment = environment
    }

    func run(prompt: String, workingDirectory: URL, screenControl: Bool = true,
             onEvent: @escaping @MainActor (CodexRunEvent) -> Void) async throws -> CodexRunResult {
        try Task.checkCancellation()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.contains("\0"), prompt.utf8.count <= 65_536 else { throw CodexCLIError.invalidPrompt }
        var directory: ObjCBool = false
        guard workingDirectory.isFileURL, !workingDirectory.path.contains("\0"),
              FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &directory),
              directory.boolValue else { throw CodexCLIError.invalidDirectory }
        let executable = try self.executable ?? Self.resolveExecutable(homeDirectory: homeDirectory,
                                                                       environment: inheritedEnvironment)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexCLIError.unavailable }
        let root = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let environment = Self.environment(executable: executable, homeDirectory: homeDirectory,
                                           inherited: inheritedEnvironment)
        var sink: AsyncThrowingStream<CodexJobUpdate, Error>.Continuation!
        // The parser's cumulative event budget bounds the stream even if the UI
        // consumer is briefly busy. No raw stderr, reasoning or tool arguments
        // enter it.
        let stream = AsyncThrowingStream<CodexJobUpdate, Error> { sink = $0 }
        let legacyServers = screenControl ? [] : Self.configuredLegacyScreenServers(homeDirectory: homeDirectory)
        let job = CodexProcessJob(executable: executable,
                                  arguments: Self.arguments(workingDirectory: root, screenControl: screenControl,
                                                            configuredLegacyServers: legacyServers),
                                  environment: environment, directory: root, prompt: prompt,
                                  timeout: timeout, outputLimit: outputLimit, sink: sink)
        return try await withTaskCancellationHandler(operation: {
            job.start()
            do {
                var result: CodexRunResult?
                for try await update in stream {
                    switch update {
                    case let .event(event):
                        // Stop may arrive while the stream is draining earlier
                        // updates; it must not revive the cancelled UI.
                        if !Task.isCancelled { onEvent(event) }
                    case let .result(value): result = value
                    }
                }
                await job.waitUntilFinished()
                try Task.checkCancellation()
                guard let result else { throw CodexCLIError.incomplete }
                return result
            } catch {
                // AsyncStream cancellation wakes its iterator immediately;
                // don't report Stop complete until our child group is reaped.
                await job.waitUntilFinished()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }, onCancel: { job.cancel() })
    }

    nonisolated static func arguments(workingDirectory: URL, screenControl: Bool = true,
                                     configuredLegacyServers: [String] = []) -> [String] {
        var arguments = ["exec", "--json", "--ephemeral", "--skip-git-repo-check",
                         "--dangerously-bypass-approvals-and-sandbox", "-m", "gpt-6-astra",
                         "-c", "model_reasoning_effort=\"medium\""]
        for feature in ["computer_use", "browser_use", "browser_use_external", "in_app_browser"] {
            arguments += [screenControl ? "--enable" : "--disable", feature]
        }
        if !screenControl {
            // CLI dotted override keys use the literal plugin ID, WITHOUT
            // embedded TOML quotes; quoted IDs are different keys in this CLI.
            for plugin in ["unified-computer-use", "computer-use", "browser", "chrome"] {
                arguments += ["-c", "plugins.\(plugin)@openai-bundled.enabled=false"]
            }
            // An override for an absent MCP server creates an invalid transport
            // table. Only disable configured legacy screen servers, and only
            // these exact names, never an arbitrary model/user-provided key.
            for server in ["node_repl", "computer-use"] where configuredLegacyServers.contains(server) {
                arguments += ["-c", "mcp_servers.\(server).enabled=false"]
            }
        }
        return arguments + ["-C", workingDirectory.path, "-"]
    }

    nonisolated static func configuredLegacyScreenServers(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let configuration = homeDirectory.appendingPathComponent(".codex/config.toml")
        guard let handle = try? FileHandle(forReadingFrom: configuration) else { return [] }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 1_048_576),
              let text = String(data: bytes, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return ["node_repl", "computer-use"].filter { server in
            let pattern = "^\\s*\\[\\s*(?:mcp_servers|\"mcp_servers\"|'mcp_servers')\\s*\\.\\s*(?:\(server)|\"\(server)\"|'\(server)')\\s*\\]\\s*(?:#.*)?$"
            return lines.contains { $0.range(of: pattern, options: .regularExpression) != nil }
        }
    }

    /// No shell evaluation, login profile or secondary wrapper is involved.
    /// GUI launches may have only /usr/bin in PATH, so discover installed Node
    /// versions as well as the native app and conventional package locations.
    nonisolated static func resolveExecutable(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                             environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let fm = FileManager.default
        let candidates = executableCandidates(homeDirectory: homeDirectory, environment: environment)
        guard let match = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw CodexCLIError.unavailable
        }
        return match
    }

    nonisolated static func locateExecutable(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                            environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        try? resolveExecutable(homeDirectory: homeDirectory, environment: environment)
    }

    nonisolated static func executableCandidates(homeDirectory: URL, environment: [String: String]) -> [URL] {
        let fixed = ["/Applications/Codex.app/Contents/Resources/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex",
                     homeDirectory.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     homeDirectory.appendingPathComponent(".local/bin/codex").path,
                     homeDirectory.appendingPathComponent(".volta/bin/codex").path]
        let versions = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nodes = ((try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("v") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/codex").path }
        let paths = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
            .map { String($0) + "/codex" }
        var seen = Set<String>()
        return (fixed + nodes + paths).filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Start from an allowlist, rather than trying to enumerate every inherited
    /// token or desktop thread variable. HOME and CODEX_HOME always identify the
    /// primary account. Its on-disk login/config stay untouched.
    nonisolated static func environment(executable: URL, homeDirectory: URL,
                                        inherited: [String: String]) -> [String: String] {
        let originalDirectory = executable.deletingLastPathComponent().path
        let resolvedDirectory = executable.resolvingSymlinksInPath().deletingLastPathComponent().path
        var pathParts = [originalDirectory, resolvedDirectory]
        let versions = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nodePaths = ((try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("v") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin").path }
        pathParts += nodePaths + [homeDirectory.appendingPathComponent(".local/bin").path,
                                  homeDirectory.appendingPathComponent(".volta/bin").path,
                                  "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        var value = ["PATH": pathParts.filter { seen.insert($0).inserted }.joined(separator: ":"),
                     "HOME": homeDirectory.path,
                     "CODEX_HOME": homeDirectory.appendingPathComponent(".codex").path,
                     "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "TERM": "dumb", "NO_COLOR": "1"]
        // macOS temporary-directory routing is useful to native tools and is
        // never copied from an alternate account or shell profile.
        value["TMPDIR"] = FileManager.default.temporaryDirectory.path
        return value
    }
}

/// Consumes only documented public JSONL events. Unknown events, including all
/// reasoning items, are ignored. Input lines, visible payloads and item IDs are
/// bounded independently; flooding cannot keep the process watcher from Stop.
struct CodexJSONLParser {
    private var line = Data()
    private var droppingLine = false
    private var emittedBytes = 0
    private var emittedCount = 0
    private var completedItems = Set<String>()
    private(set) var finalText = ""
    private(set) var completed = false
    private(set) var failure: String?
    private(set) var truncated = false
    private(set) var malformedLines = 0
    let outputLimit: Int
    let lineLimit: Int

    init(outputLimit: Int = 262_144, lineLimit: Int = 1_048_576) {
        self.outputLimit = max(256, outputLimit)
        self.lineLimit = max(256, lineLimit)
    }

    mutating func feed(_ bytes: Data) -> [CodexRunEvent] {
        var events: [CodexRunEvent] = []
        for byte in bytes {
            if byte == 10 {
                if !droppingLine { events += consumeLine() }
                line.removeAll(keepingCapacity: true)
                droppingLine = false
            } else if !droppingLine {
                if line.count < lineLimit { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); droppingLine = true; truncated = true }
            }
        }
        return events
    }

    mutating func finish() -> [CodexRunEvent] {
        defer { line.removeAll(); droppingLine = false }
        return droppingLine || line.isEmpty ? [] : consumeLine()
    }

    private mutating func consumeLine() -> [CodexRunEvent] {
        guard !line.isEmpty else { return [] }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { malformedLines += 1; return [] }
        var result: [CodexRunEvent] = []
        switch type {
        case "thread.started": result = [.started]
        case "turn.started": result = [.thinking]
        case "turn.completed": completed = true; result = [.completed]
        case "turn.failed", "error":
            let detail = (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String
            failure = Self.visibleText(detail ?? "The CLI reported an error.", limit: 2_000)
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any], let kind = item["type"] as? String else { return [] }
            let finished = type == "item.completed"
            let started = type == "item.started"
            if finished, let id = item["id"] as? String {
                if completedItems.contains(id) { return [] }
                if completedItems.count < 8_192 { completedItems.insert(id) }
            }
            switch kind {
            case "agent_message" where finished:
                let value = Self.visibleText(item["text"] as? String ?? "", limit: outputLimit)
                if !value.isEmpty {
                    // Newer CLI versions label commentary/final_answer. Older
                    // versions omit phase and the last agent message is final.
                    let phase = item["phase"] as? String
                    if phase == nil || phase == "final_answer" { finalText = value }
                    result = [.message(value)]
                }
            case "command_execution":
                let command = Self.visibleText(item["command"] as? String ?? "Terminal command", limit: 8_192)
                if started { result = [.commandStarted(command)] }
                else if finished {
                    result = [.commandFinished(command: command,
                                               output: Self.visibleText(item["aggregated_output"] as? String ?? "", limit: 32_768),
                                               exitCode: (item["exit_code"] as? NSNumber)?.intValue)]
                }
            case "file_change" where finished:
                let paths = (item["changes"] as? [[String: Any]] ?? []).prefix(128)
                    .compactMap { ($0["path"] as? String).map { Self.visibleText($0, limit: 2_048) } }
                if !paths.isEmpty { result = [.filesChanged(paths)] }
            case "mcp_tool_call":
                // Arguments and response payloads may contain private content;
                // only the actual server/tool name is needed for progress.
                let server = item["server"] as? String ?? "Connected tool"
                let tool = item["tool"] as? String ?? ""
                let label = Self.visibleText(tool.isEmpty ? server : "\(server): \(tool)", limit: 512)
                if started { result = [.toolStarted(label)] }
                else if finished { result = [.toolFinished(label)] }
            case "web_search":
                let query = Self.visibleText(item["query"] as? String ?? "Searching the web", limit: 1_024)
                if started { result = [.toolStarted("Search: \(query)")] }
                else if finished { result = [.toolFinished("Search: \(query)")] }
            default: break
            }
        default: break
        }
        return result.filter { event in
            let size = Self.eventSize(event)
            guard emittedCount < 8_192, emittedBytes + size <= outputLimit else { truncated = true; return false }
            emittedCount += 1; emittedBytes += size
            return true
        }
    }

    private static func eventSize(_ event: CodexRunEvent) -> Int {
        switch event {
        case let .message(text), let .commandStarted(text), let .toolStarted(text), let .toolFinished(text), let .status(text): return text.utf8.count + 32
        case let .commandFinished(command, output, _): return command.utf8.count + output.utf8.count + 32
        case let .filesChanged(paths): return paths.reduce(32) { $0 + $1.utf8.count }
        default: return 32
        }
    }

    static func visibleText(_ value: String, limit: Int) -> String {
        // Strip terminal escape/control codes before native text rendering.
        let unescaped = value.replacingOccurrences(of: "\\u001B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let cleaned = String(unescaped.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })
        var bytes = Data(cleaned.utf8.prefix(max(0, limit)))
        // Avoid introducing a replacement glyph when the byte cap cuts UTF-8.
        while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}

private enum CodexJobUpdate: Sendable {
    case event(CodexRunEvent)
    case result(CodexRunResult)
}

/// An owned process group, not Process.terminate(): the npm CLI spawns a native
/// child, and its commands must stop with it. Deliberately detached processes
/// can escape a group; cancellation does not undo completed filesystem changes.
private final class CodexProcessJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.chad.quick-dictate.codex", qos: .userInitiated)
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let directory: URL
    private var input: Data
    private var inputOffset = 0
    private let timeout: TimeInterval
    private let sink: AsyncThrowingStream<CodexJobUpdate, Error>.Continuation
    private var parser: CodexJSONLParser
    private var stderrData = Data()
    private var stdoutFD: Int32 = -1
    private var stderrFD: Int32 = -1
    private var stdinFD: Int32 = -1
    private var pid: pid_t = 0
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var timedOut = false
    private var startedAt: TimeInterval = 0
    private var stoppingAt: TimeInterval?
    private var rootReaped = false
    private var exitCode: Int32 = -1
    private var killSent = false
    private var finished = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         prompt: String, timeout: TimeInterval, outputLimit: Int,
         sink: AsyncThrowingStream<CodexJobUpdate, Error>.Continuation) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.directory = directory; self.input = Data(prompt.utf8); self.timeout = timeout
        self.parser = CodexJSONLParser(outputLimit: outputLimit); self.sink = sink
    }

    func start() {
        queue.async {
            if self.cancelled { self.finish(error: CancellationError()); return }
            do { try self.spawn() }
            catch { self.finish(error: error); return }
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
            guard !self.finished else { return }
            self.cancelled = true
            if self.pid > 0 { self.beginStopping() }
        }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.finished { continuation.resume() }
                else { self.completionWaiters.append(continuation) }
            }
        }
    }

    private func spawn() throws {
        var output: [Int32] = [-1, -1], diagnostic: [Int32] = [-1, -1], inputPipe: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw CodexCLIError.launchFailed }
        guard pipe(&diagnostic) == 0 else { output.forEach { close($0) }; throw CodexCLIError.launchFailed }
        guard pipe(&inputPipe) == 0 else { (output + diagnostic).forEach { close($0) }; throw CodexCLIError.launchFailed }
        var keepParentEnds = false
        defer {
            [output[1], diagnostic[1], inputPipe[0]].forEach { close($0) }
            if !keepParentEnds { [output[0], diagnostic[0], inputPipe[1]].forEach { close($0) } }
        }
        for fd in output + diagnostic + inputPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        for fd in [output[0], diagnostic[0], inputPipe[1]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        // A child closing stdin early must not deliver SIGPIPE to the app.
        _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CodexCLIError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CodexCLIError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        let chdir: Int32
        if #available(macOS 26.0, *) { chdir = posix_spawn_file_actions_addchdir(&actions, directory.path) }
        else { chdir = posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        var setup = [chdir,
                     posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, diagnostic[1], STDERR_FILENO),
                     posix_spawnattr_setpgroup(&attributes, 0),
                     posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))]
        for fd in output + diagnostic + inputPipe { setup.append(posix_spawn_file_actions_addclose(&actions, fd)) }
        guard setup.allSatisfy({ $0 == 0 }) else { throw CodexCLIError.launchFailed }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let status = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard status == 0, pid > 0 else { pid = 0; throw CodexCLIError.launchFailed }
        stdoutFD = output[0]; stderrFD = diagnostic[0]; stdinFD = inputPipe[1]
        keepParentEnds = true
    }

    private func tick() {
        guard !finished else { return }
        writeInput()
        drain()
        if !rootReaped {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                rootReaped = true
                exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                beginStopping()
            } else if result == -1 && errno == ECHILD { rootReaped = true; beginStopping() }
        }
        if rootReaped, kill(-pid, 0) == -1, errno == ESRCH { drain(); finish(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if stoppingAt == nil && now - startedAt >= timeout { timedOut = true; beginStopping() }
        if let stoppingAt, now - stoppingAt >= 0.25 {
            if !killSent { _ = kill(-pid, SIGKILL); killSent = true }
            if rootReaped && now - stoppingAt >= 0.3 { drain(); finish() }
        }
    }

    private func writeInput() {
        guard stdinFD >= 0 else { return }
        while inputOffset < input.count {
            let count = input.withUnsafeBytes { bytes in
                write(stdinFD, bytes.baseAddress!.advanced(by: inputOffset), input.count - inputOffset)
            }
            if count > 0 { inputOffset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { close(stdinFD); stdinFD = -1; input.removeAll(); return }
        }
        close(stdinFD); stdinFD = -1; input.removeAll()
    }

    private func drain() {
        for fd in [stdoutFD, stderrFD] where fd >= 0 {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            for _ in 0..<32 {
                let count = read(fd, &bytes, bytes.count)
                if count < 0 { if errno == EINTR { continue }; break }
                if count == 0 { break }
                if fd == stdoutFD {
                    for event in parser.feed(Data(bytes.prefix(count))) { sink.yield(.event(event)) }
                } else {
                    // Diagnostics are retained only to identify an auth failure;
                    // arbitrary stderr can include private configuration details.
                    let remaining = max(0, 8_192 - stderrData.count)
                    stderrData.append(contentsOf: bytes.prefix(min(count, remaining)))
                }
            }
        }
    }

    private func beginStopping() {
        guard stoppingAt == nil, pid > 0 else { return }
        stoppingAt = ProcessInfo.processInfo.systemUptime
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1; input.removeAll() }
        _ = kill(-pid, SIGTERM)
    }

    private func finish(error: Error? = nil) {
        guard !finished else { return }
        finished = true
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        for event in parser.finish() { sink.yield(.event(event)) }
        for fd in [stdinFD, stdoutFD, stderrFD] where fd >= 0 { close(fd) }
        stdinFD = -1; stdoutFD = -1; stderrFD = -1
        input.removeAll()
        if let error { sink.finish(throwing: error) }
        else if cancelled { sink.finish(throwing: CancellationError()) }
        else if timedOut { sink.finish(throwing: CodexCLIError.timeout) }
        else if let message = parser.failure { sink.finish(throwing: CodexCLIError.failed(message)) }
        else if exitCode != 0 {
            let diagnostics = String(decoding: stderrData, as: UTF8.self).lowercased()
            let authFailure = ["not logged in", "unauthorized", "authentication", "401", "login", "sign in"]
                .contains { diagnostics.contains($0) }
            sink.finish(throwing: CodexCLIError.failed(authFailure
                ? "Sign in with `codex login` on your primary account, then try again."
                : "The CLI exited with status \(exitCode). Check your Codex installation and primary-account login."))
        } else if !parser.completed || parser.finalText.isEmpty {
            sink.finish(throwing: CodexCLIError.incomplete)
        } else {
            sink.yield(.result(CodexRunResult(finalText: parser.finalText, exitCode: exitCode, truncated: parser.truncated)))
            sink.finish()
        }
        stderrData.removeAll()
        let waiters = completionWaiters
        completionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
