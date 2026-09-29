import Foundation
import Darwin

private final class ActionOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ chunk: String) { lock.lock(); defer { lock.unlock() }; value += chunk }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

extension CoreTests {
    @MainActor static func localActionChecks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("quick-dictate-actions-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work", isDirectory: true)
        let sibling = root.appendingPathComponent("work-other", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let sample = work.appendingPathComponent("sample.txt")
        try Data("fixture".utf8).write(to: sample)
        let executor = LocalActionExecutor()
        func reviewed(_ command: String, at directory: URL? = nil) throws -> ReviewedLocalAction {
            try ReviewedLocalAction(action: .shell(command: command, directory: directory ?? work), workRoot: work)
        }
        func proposal(_ name: String, _ arguments: [String: Any]) throws -> LocalAction {
            try LocalAction.proposal(toolName: name, arguments: arguments, workRoot: work)
        }
        let parsed = try proposal("run_terminal", ["command": "printf safe"])
        check(parsed == .shell(command: "printf safe", directory: work.resolvingSymlinksInPath()), "Terminal proposal resolves the local chosen folder")
        check(!fm.fileExists(atPath: work.appendingPathComponent("not-executed").path), "Parsing proposals has no execution side effects")
        _ = try proposal("run_terminal", ["command": "touch not-executed"])
        check(!fm.fileExists(atPath: work.appendingPathComponent("not-executed").path), "Even a write command is only a proposal until reviewed")
        let fileProposal = try proposal("open_file", ["path": "sample.txt"])
        check(fileProposal == .openFile(sample.resolvingSymlinksInPath()), "Relative file resolves under chosen folder")
        let urlProposal = try proposal("open_url", ["url": "https://example.com/test"])
        check(urlProposal == .openURL(URL(string: "https://example.com/test")!), "HTTP website accepted as proposal without opening")
        await expectError("unsupported arguments") { _ = try proposal("run_terminal", ["command": "pwd", "workRoot": "/"]) }
        await expectError("not supported") { _ = try proposal("delete_everything", [:]) }
        await expectError("valid command") { _ = try proposal("run_terminal", ["command": 7]) }
        let emptyDirectory = try proposal("run_terminal", ["command": "pwd", "directory": ""])
        check(emptyDirectory == .shell(command: "pwd", directory: work.resolvingSymlinksInPath()),
              "An empty optional directory from a model uses the chosen working folder")
        await expectError("valid directory") { _ = try proposal("run_terminal", ["command": "pwd", "directory": 7]) }
        await expectError("outside") { _ = try proposal("run_terminal", ["command": "pwd", "directory": "../work-other"]) }
        await expectError("existing directory") { _ = try proposal("run_terminal", ["command": "pwd", "directory": "sample.txt"]) }
        await expectError("does not exist") { _ = try proposal("open_file", ["path": "missing.txt"]) }
        await expectError("outside") { _ = try proposal("open_file", ["path": sibling.path]) }
        await expectError("HTTP or HTTPS") { _ = try proposal("open_url", ["url": "file:///etc/passwd"]) }
        await expectError("HTTP or HTTPS") { _ = try proposal("open_url", ["url": "javascript:alert(1)"]) }
        await expectError("HTTP or HTTPS") { _ = try proposal("open_url", ["url": "https://user:password@example.com/"]) }
        await expectError("HTTP or HTTPS") { _ = try proposal("open_url", ["url": "https:/missing-host"]) }
        await expectError("full path") { _ = try proposal("open_application", ["path": "Calculator.app"]) }
        await expectError("existing app") { _ = try proposal("open_application", ["path": "/Applications/QuickDictateMissing-\(UUID().uuidString).app"]) }
        await expectError("existing app") { _ = try proposal("open_application", ["path": sample.path]) }
        await expectError("16,384") { _ = try reviewed(String(repeating: "a", count: 16_385)) }
        await expectError("16,384") { _ = try reviewed("printf a\0printf b") }
        await expectError("working folder") { _ = try ReviewedLocalAction(action: parsed, workRoot: sample) }
        let escapedLink = work.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(at: escapedLink, withDestinationURL: sibling)
        await expectError("outside") { _ = try proposal("open_file", ["path": "outside-link"]) }
        await expectError("outside") { _ = try proposal("run_terminal", ["command": "pwd", "directory": "outside-link"]) }
        let credentials = work.appendingPathComponent(".credentials", isDirectory: true)
        try fm.createDirectory(at: credentials, withIntermediateDirectories: true)
        let fakeSecret = credentials.appendingPathComponent("fake.env")
        try Data("fixture-only".utf8).write(to: fakeSecret)
        await expectError("Credential") { _ = try proposal("open_file", ["path": fakeSecret.path]) }
        for name in [".env", ".env.local", "test.pem", "test.keychain-db"] {
            try Data("fixture-only".utf8).write(to: work.appendingPathComponent(name))
            await expectError("Credential") { _ = try proposal("open_file", ["path": name]) }
        }
        let environment = LocalActionExecutor.terminalEnvironment(home: work.path)
        check(Set(environment.keys) == ["PATH", "HOME", "LANG", "LC_CTYPE", "TERM", "NO_COLOR"], "Terminal inherits only six explicitly allowed environment variables")
        check(environment["CODEX_HOME"] == nil && environment["OPENROUTER_API_KEY"] == nil && environment["SSH_AUTH_SOCK"] == nil, "No auth or secondary-account environment is inherited")
        check(environment["HOME"] == work.path, "Environment home can be isolated in tests")

        let stream = ActionOutputCollector()
        let basic = try await executor.run(reviewed("printf 'hello'; printf ' error' >&2; exit 7"), onOutput: { stream.append($0) })
        check(basic.output == "hello error" && stream.text == basic.output, "Live output and final result merge stdout and stderr once")
        check(basic.exitCode == 7 && !basic.succeeded && !basic.timedOut && !basic.cancelled, "Nonzero status is a visible failed result")
        let pwd = try await executor.run(reviewed("pwd"))
        let actualFolder = URL(fileURLWithPath: pwd.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        check(actualFolder == work.resolvingSymlinksInPath(), "Terminal executes in exactly the reviewed working directory")
        check(pwd.succeeded && pwd.exitCode == 0, "Successful terminal status is preserved")
        let unicode = try await executor.run(reviewed("printf 'Crème brûlée 日本語'"))
        check(unicode.output == "Crème brûlée 日本語", "Terminal preserves UTF-8 output")
        let standardInput = try await executor.run(reviewed("if read answer; then printf unexpected; else printf closed; fi"))
        check(standardInput.output == "closed", "Commands cannot hang waiting for interactive input")

        let cappedStream = ActionOutputCollector()
        let flood = try await executor.run(reviewed("i=0; while [ \"$i\" -lt 10000 ]; do printf 'abcdefghij'; i=$((i + 1)); done"), outputLimit: 1024, onOutput: { cappedStream.append($0) })
        check(flood.succeeded && flood.truncated && flood.output.utf8.count == 1024, "Large output is drained without deadlock and capped")
        check(cappedStream.text == flood.output, "Live output obeys the same memory cap")

        let started = ProcessInfo.processInfo.systemUptime
        let timeout = try await executor.run(reviewed("/bin/sleep 10 & child=$!; printf '%s' \"$child\"; wait \"$child\""), timeout: 0.15)
        check(timeout.timedOut && !timeout.cancelled && !timeout.succeeded, "Timeout has a distinct visible result")
        check(ProcessInfo.processInfo.systemUptime - started < 2, "Timeout promptly returns instead of blocking the main actor")
        if let child = Int32(timeout.output) {
            var alive = kill(child, 0) == 0
            for _ in 0..<20 where alive {
                try await Task.sleep(nanoseconds: 25_000_000)
                alive = kill(child, 0) == 0
            }
            if alive { _ = kill(child, SIGKILL) } // Own test child's cleanup if a regression is detected.
            check(!alive, "Timeout terminates the command's background child, not just the shell")
        } else { check(false, "Timeout fixture reported its child PID") }

        let uncooperativeStart = ProcessInfo.processInfo.systemUptime
        let uncooperative = try await executor.run(reviewed("trap '' TERM; printf ready; while :; do /bin/sleep 1; done"), timeout: 0.1)
        check(uncooperative.timedOut && uncooperative.exitCode == 128 + SIGKILL,
              "Timeout escalates to SIGKILL when the shell ignores SIGTERM")
        check(ProcessInfo.processInfo.systemUptime - uncooperativeStart < 2,
              "A SIGTERM-resistant command cannot leave execution stuck")

        let cancellation = Task { try await executor.run(reviewed("printf started; /bin/sleep 10; printf late")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancellation.cancel()
        let cancelled = try await cancellation.value
        check(cancelled.cancelled && !cancelled.timedOut && !cancelled.succeeded, "Task cancellation stops the local command")
        check(cancelled.output == "started", "Cancelled command cannot continue to later statements")
        let immediate = Task { try await executor.run(reviewed("printf must-not-run")) }
        immediate.cancel()
        let early = try await immediate.value
        check(early.cancelled && early.output.isEmpty, "Cancellation before launch performs no command")

        let exitingParent = try await executor.run(reviewed("/bin/sleep 10 & printf '%s' \"$!\"; exit 0"))
        if let child = Int32(exitingParent.output) {
            var alive = kill(child, 0) == 0
            for _ in 0..<20 where alive {
                try await Task.sleep(nanoseconds: 25_000_000)
                alive = kill(child, 0) == 0
            }
            if alive { _ = kill(child, SIGKILL) }
            check(exitingParent.succeeded && !alive, "Successful shell exit also cleans up its background children")
        } else { check(false, "Background cleanup fixture reported its child PID") }

        let raceDirectory = work.appendingPathComponent("replaced-folder", isDirectory: true)
        try fm.createDirectory(at: raceDirectory, withIntermediateDirectories: true)
        let stale = try reviewed("printf must-not-run", at: raceDirectory)
        try fm.removeItem(at: raceDirectory)
        try fm.createSymbolicLink(at: raceDirectory, withDestinationURL: sibling)
        await expectError("outside") { _ = try await executor.run(stale) }
        let missing = try reviewed("printf must-not-run", at: work)
        try fm.moveItem(at: work, to: root.appendingPathComponent("moved-work"))
        await expectError("working folder") { _ = try await executor.run(missing) }
    }
}
