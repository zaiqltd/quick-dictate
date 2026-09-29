import Foundation
import Darwin

extension CoreTests {
    @MainActor static func codexCLIChecks() async throws {
        func check(_ condition: Bool, _ description: String) { Self.check(condition, description) }
        func json(_ object: [String: Any], newline: Bool = true) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if newline { data.append(10) }
            return data
        }
        func item(_ type: String, _ body: [String: Any]) throws -> Data {
            try json(["type": type, "item": body])
        }
        var parser = CodexJSONLParser()
        check(parser.feed(try json(["type": "thread.started", "thread_id": "fixture"])).contains(.started), "Codex reports the actual thread-start event")
        check(parser.feed(try json(["type": "turn.started"])).contains(.thinking), "Codex reports actual thinking without reasoning text")
        check(parser.feed(try item("item.completed", ["id": "secret-reason", "type": "reasoning", "text": "PRIVATE REASONING"])).isEmpty,
              "Codex never emits reasoning items")
        let command = "printf 'hello'"
        check(parser.feed(try item("item.started", ["id": "cmd", "type": "command_execution", "command": command])).contains(.commandStarted(command)),
              "Codex command starts are shown before completion")
        check(parser.feed(try item("item.completed", ["id": "cmd", "type": "command_execution", "command": command,
                                                     "aggregated_output": "hello", "exit_code": 0])).contains(.commandFinished(command: command, output: "hello", exitCode: 0)),
              "Codex command completion preserves real output and exit status")
        check(parser.feed(try item("item.completed", ["id": "cmd", "type": "command_execution", "command": command])).isEmpty,
              "Duplicate completed Codex items are not repeated")
        check(parser.feed(try item("item.completed", ["id": "file", "type": "file_change", "changes": [["path": "Sources/New.swift", "kind": "add"]]])).contains(.filesChanged(["Sources/New.swift"])),
              "Codex file-change progress contains reported paths")
        check(parser.feed(try item("item.started", ["type": "mcp_tool_call", "server": "screen", "tool": "inspect", "arguments": ["private": "must not appear"]])).contains(.toolStarted("screen: inspect")),
              "Codex tool progress includes the server/name without arguments")
        check(parser.feed(try item("item.completed", ["id": "tool", "type": "mcp_tool_call", "server": "screen", "tool": "inspect", "result": "private"])).contains(.toolFinished("screen: inspect")),
              "Codex tool completion omits arbitrary tool payloads")
        check(parser.feed(try item("item.started", ["type": "web_search", "query": "official Swift docs"])).contains(.toolStarted("Search: official Swift docs")),
              "Codex actual web search is visible")
        check(parser.feed(try item("item.completed", ["id": "web", "type": "web_search", "query": "official Swift docs"])).contains(.toolFinished("Search: official Swift docs")),
              "Codex search completion is visible")
        check(parser.feed(try item("item.completed", ["id": "commentary", "type": "agent_message", "phase": "commentary", "text": "I'm checking the files."])).contains(.message("I'm checking the files.")),
              "Codex public commentary is shown")
        check(parser.finalText.isEmpty, "Public commentary is not mistaken for a labelled final answer")
        let final = try item("item.completed", ["id": "answer", "type": "agent_message", "phase": "final_answer", "text": "Finished — 日本語 ✓"])
        var finalEvents: [CodexRunEvent] = []
        for byte in final { finalEvents += parser.feed(Data([byte])) }
        check(finalEvents == [.message("Finished — 日本語 ✓")], "Codex JSONL handles arbitrary split UTF-8 bytes")
        check(parser.finalText == "Finished — 日本語 ✓", "Codex returns the labelled final answer")
        check(parser.feed(try json(["type": "turn.completed", "usage": ["input_tokens": 4]])).contains(.completed) && parser.completed,
              "Codex only marks completion from a real completed turn")
        var legacy = CodexJSONLParser()
        _ = legacy.feed(try item("item.completed", ["type": "agent_message", "text": "Legacy final answer"]))
        check(legacy.finalText == "Legacy final answer", "Codex supports older CLI agent messages without a phase")
        var trailing = CodexJSONLParser()
        _ = trailing.feed(try json(["type": "turn.started"], newline: false))
        check(trailing.finish() == [.thinking], "Codex accepts a final JSONL line without a newline")
        var unknown = CodexJSONLParser()
        check(unknown.feed(Data("bad json\n{\"type\":\"unknown\"}\n".utf8)).isEmpty && unknown.malformedLines == 1,
              "Codex ignores unknown events and counts malformed lines without exposing them")
        var failed = CodexJSONLParser()
        _ = failed.feed(try json(["type": "turn.failed", "error": ["message": "The service is unavailable."]]))
        check(failed.failure == "The service is unavailable." && !failed.completed, "Codex failed turns retain the actual public error")
        var capped = CodexJSONLParser(outputLimit: 256, lineLimit: 256)
        check(capped.feed(Data((String(repeating: "x", count: 512) + "\n").utf8)).isEmpty && capped.truncated,
              "Oversized Codex lines are discarded within a bounded line buffer")
        check(capped.feed(try json(["type": "turn.completed"])) == [.completed] && capped.completed,
              "Parser recovers after an oversized line")
        var flooded = CodexJSONLParser(outputLimit: 256)
        var visible: [CodexRunEvent] = []
        for _ in 0..<100 { visible += flooded.feed(try json(["type": "turn.started"])) }
        check(visible.count == 8 && flooded.truncated, "Codex's cumulative event cap bounds a slow UI consumer")
        check(CodexJSONLParser.visibleText("\u{1b}[31mred\u{1b}[0m\0\r\nline", limit: 128) == "red\nline",
              "Codex strips terminal escapes and controls before displaying text")
        check(CodexJSONLParser.visibleText("日本語", limit: 4) == "日", "Codex text caps do not split Unicode scalars")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("quick-dictate-codex-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let work = root.appendingPathComponent("work with spaces", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func fixture(_ name: String, _ body: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let end = """
        printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","type":"agent_message","phase":"final_answer","text":"Done."}}'
        printf '%s\\n' '{"type":"turn.completed"}'
        """
        let basic = try fixture("fake-codex", """
        /bin/cat > prompt.txt
        printf '%s\\n' "$@" > arguments.txt
        /usr/bin/env > environment.txt
        /bin/pwd > folder.txt
        printf '%s\\n' '{"type":"thread.started","thread_id":"fixture"}'
        printf '%s\\n' '{"type":"turn.started"}'
        printf '%s\\n' '{"type":"item.started","item":{"id":"command","type":"command_execution","command":"printf fixture"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"command","type":"command_execution","command":"printf fixture","aggregated_output":"fixture","exit_code":0}}'
        \(end)
        """)
        let inherited = ["PATH": "/untrusted", "HOME": "/wrong", "CODEX_HOME": "/secondary",
                         "OPENAI_API_KEY": "not-a-real-key", "CODEX_API_KEY": "not-a-real-key",
                         "OPENROUTER_API_KEY": "not-a-real-key", "CODEX_THREAD_ID": "parent-thread",
                         "CODEX_SHELL": "/bin/false", "NODE_OPTIONS": "must-not-inherit", "SSH_AUTH_SOCK": "/wrong"]
        let environment = CodexCLI.environment(executable: basic, homeDirectory: home, inherited: inherited)
        check(environment["HOME"] == home.path && environment["CODEX_HOME"] == home.appendingPathComponent(".codex").path,
              "Codex environment explicitly pins the primary HOME and CODEX_HOME")
        check(Set(environment.keys) == ["PATH", "HOME", "CODEX_HOME", "LANG", "LC_CTYPE", "TERM", "NO_COLOR", "TMPDIR"],
              "Codex inherits only its minimal primary-account environment")
        check(environment["PATH"]!.hasPrefix(basic.deletingLastPathComponent().path + ":"), "Codex GUI PATH starts with the selected executable directory")
        check(environment.values.allSatisfy { !$0.contains("not-a-real-key") && !$0.contains("secondary") },
              "Codex excludes inherited API keys, secondary account settings and thread metadata")
        let nvmOld = home.appendingPathComponent(".nvm/versions/node/v9.9.0/bin", isDirectory: true)
        let nvmNew = home.appendingPathComponent(".nvm/versions/node/v24.16.0/bin", isDirectory: true)
        try fm.createDirectory(at: nvmOld, withIntermediateDirectories: true)
        try fm.createDirectory(at: nvmNew, withIntermediateDirectories: true)
        let candidates = CodexCLI.executableCandidates(homeDirectory: home, environment: ["PATH": "/custom/bin:relative:.:/custom/bin"])
        let oldIndex = candidates.firstIndex { $0.path.hasSuffix("/v9.9.0/bin/codex") }!
        let newIndex = candidates.firstIndex { $0.path.hasSuffix("/v24.16.0/bin/codex") }!
        check(newIndex < oldIndex, "Codex discovers newest NVM versions by numeric version order")
        check(candidates.filter { $0.path == "/custom/bin/codex" }.count == 1, "Codex candidate paths are deduplicated")
        check(!candidates.contains { $0.path.contains("/relative/") }, "Codex ignores relative inherited PATH entries")
        let nodeEnvironment = CodexCLI.environment(executable: basic, homeDirectory: home, inherited: [:])
        check(nodeEnvironment["PATH"]!.contains("/v24.16.0/bin"), "GUI Codex launches can find Node outside the login-shell PATH")
        let primaryConfig = home.appendingPathComponent(".codex/config.toml")
        try fm.createDirectory(at: primaryConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        check(CodexCLI.configuredLegacyScreenServers(homeDirectory: home).isEmpty, "Missing Codex config does not invent legacy screen server overrides")
        try Data("""
        # [mcp_servers.node_repl]
        [mcp_servers.other]
        command = "fixture"
        [mcp_servers.\"node_repl\"] # supported legacy screen server
        command = "fixture"
        ['mcp_servers'.'computer-use']
        command = "fixture"
        """.utf8).write(to: primaryConfig)
        check(CodexCLI.configuredLegacyScreenServers(homeDirectory: home) == ["node_repl", "computer-use"],
              "Codex detects only exact configured legacy screen-server table headers including quoted names")
        let offArgs = CodexCLI.arguments(workingDirectory: work, screenControl: false,
                                         configuredLegacyServers: ["node_repl", "computer-use", "other"])
        check(offArgs.filter { $0 == "--disable" }.count == 4 && !offArgs.contains("--enable"),
              "Screen control off disables all four native UI/browser features for this run")
        check(["unified-computer-use", "computer-use", "browser", "chrome"].allSatisfy {
            offArgs.contains("plugins.\($0)@openai-bundled.enabled=false")
        }, "Screen control off disables configured native UI plugin families with verified unquoted override keys")
        check(offArgs.contains("mcp_servers.node_repl.enabled=false") && offArgs.contains("mcp_servers.computer-use.enabled=false")
              && !offArgs.contains("mcp_servers.other.enabled=false"), "Screen control overrides only the two allowed legacy screen servers")
        check(!CodexCLI.arguments(workingDirectory: work, screenControl: false).contains { $0.hasPrefix("mcp_servers.") },
              "Absent legacy screen servers never create invalid MCP config tables")
        let onArgs = CodexCLI.arguments(workingDirectory: work, screenControl: true, configuredLegacyServers: ["node_repl"])
        check(onArgs.filter { $0 == "--enable" }.count == 4 && !onArgs.contains("--disable")
              && !onArgs.contains { $0.hasPrefix("mcp_servers.") || $0.hasPrefix("plugins.") },
              "Screen control on enables native features without mutating saved plugin or server configuration")

        let runner = CodexCLI(executable: basic, homeDirectory: home, timeout: 3, environment: inherited)
        let prompt = "Build a thing; $(touch SHOULD-NOT-EXIST) `touch ALSO-NOT`\nUnicode: 日本語"
        var events: [CodexRunEvent] = []
        let result = try await runner.run(prompt: prompt, workingDirectory: work) { events.append($0) }
        check(result.finalText == "Done." && result.exitCode == 0 && !result.truncated, "Codex returns a completed fake process result")
        check(events == [.started, .thinking, .commandStarted("printf fixture"), .commandFinished(command: "printf fixture", output: "fixture", exitCode: 0), .message("Done."), .completed],
              "Codex delivers process events in order on the main actor")
        check(try String(contentsOf: work.appendingPathComponent("prompt.txt"), encoding: .utf8) == prompt, "Codex prompt is delivered literally through stdin")
        check(!fm.fileExists(atPath: work.appendingPathComponent("SHOULD-NOT-EXIST").path) && !fm.fileExists(atPath: work.appendingPathComponent("ALSO-NOT").path),
              "Codex never shell-interpolates user prompts")
        let args = try String(contentsOf: work.appendingPathComponent("arguments.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        check(args == CodexCLI.arguments(workingDirectory: work.resolvingSymlinksInPath()), "Codex forwards the exact fixed argv, including folder with spaces")
        check(args.contains("--dangerously-bypass-approvals-and-sandbox") && args.contains("gpt-6-astra") && args.contains("model_reasoning_effort=\"medium\""),
              "Full Control runs the user-requested Astra medium with bypass permissions")
        check(args.contains("--ephemeral") && args.contains("--skip-git-repo-check") && args.last == "-", "Codex runs ephemeral sessions outside Git with stdin prompts")
        let processEnvironment = try String(contentsOf: work.appendingPathComponent("environment.txt"), encoding: .utf8)
        check(processEnvironment.contains("CODEX_HOME=\(home.path)/.codex") && !processEnvironment.contains("not-a-real-key") && !processEnvironment.contains("parent-thread"),
              "Spawned Codex process receives primary auth location without inherited secrets or session metadata")
        let actualFolder = try String(contentsOf: work.appendingPathComponent("folder.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        check(URL(fileURLWithPath: actualFolder).resolvingSymlinksInPath() == work.resolvingSymlinksInPath(),
              "Codex starts in the exact selected folder")
        _ = try await runner.run(prompt: "screen off fixture", workingDirectory: work, screenControl: false) { _ in }
        let actualOffArguments = try String(contentsOf: work.appendingPathComponent("arguments.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        check(actualOffArguments == CodexCLI.arguments(workingDirectory: work.resolvingSymlinksInPath(), screenControl: false,
                                                      configuredLegacyServers: ["node_repl", "computer-use"]),
              "Spawned Codex applies screen control off settings and detected legacy overrides")
        check(try String(contentsOf: primaryConfig, encoding: .utf8).contains("[mcp_servers.\"node_repl\"]"),
              "Per-run screen control changes do not rewrite the primary Codex configuration")
        await expectError("65,536") { _ = try await runner.run(prompt: " ", workingDirectory: work) { _ in } }
        await expectError("65,536") { _ = try await runner.run(prompt: String(repeating: "x", count: 65_537), workingDirectory: work) { _ in } }
        await expectError("65,536") { _ = try await runner.run(prompt: "a\0b", workingDirectory: work) { _ in } }
        await expectError("existing local folder") { _ = try await runner.run(prompt: "test", workingDirectory: basic) { _ in } }
        await expectError("existing local folder") { _ = try await runner.run(prompt: "test", workingDirectory: URL(string: "https://example.com")!) { _ in } }
        await expectError("not found") {
            _ = try await CodexCLI(executable: root.appendingPathComponent("missing"), homeDirectory: home)
                .run(prompt: "test", workingDirectory: work) { _ in }
        }
        let failure = try fixture("fake-failure", "/bin/cat >/dev/null\nprintf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"message\":\"Fixture provider failure\"}}'\nexit 1")
        await expectError("Fixture provider failure") {
            _ = try await CodexCLI(executable: failure, homeDirectory: home).run(prompt: "test", workingDirectory: work) { _ in }
        }
        let auth = try fixture("fake-auth", "/bin/cat >/dev/null\nprintf '401 Unauthorized secret-detail' >&2\nexit 1")
        await expectError("codex login") {
            _ = try await CodexCLI(executable: auth, homeDirectory: home).run(prompt: "test", workingDirectory: work) { _ in }
        }
        let empty = try fixture("fake-incomplete", "/bin/cat >/dev/null\nprintf '%s\\n' '{\"type\":\"turn.started\"}'")
        await expectError("complete answer") {
            _ = try await CodexCLI(executable: empty, homeDirectory: home).run(prompt: "test", workingDirectory: work) { _ in }
        }
        let closedInput = try fixture("fake-closed-input", "exec 0<&-\n\(end)")
        let inputResult = try await CodexCLI(executable: closedInput, homeDirectory: home).run(prompt: String(repeating: "a", count: 65_536), workingDirectory: work) { _ in }
        check(inputResult.finalText == "Done.", "A CLI that closes stdin early cannot SIGPIPE-crash Quick Dictate")

        func assertChildGone(_ marker: String, _ description: String) async throws {
            let child = Int32(try String(contentsOf: work.appendingPathComponent(marker), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            var alive = kill(child, 0) == 0
            for _ in 0..<20 where alive {
                try await Task.sleep(nanoseconds: 25_000_000)
                alive = kill(child, 0) == 0
            }
            if alive { _ = kill(child, SIGKILL) }
            check(!alive, description)
        }
        let waiting = try fixture("fake-waiting", """
        /bin/cat >/dev/null
        /bin/sleep 10 &
        printf '%s' "$!" > child-pid
        printf '%s\\n' '{"type":"turn.started"}'
        wait
        """)
        let start = ProcessInfo.processInfo.systemUptime
        await expectError("time limit") {
            _ = try await CodexCLI(executable: waiting, homeDirectory: home, timeout: 1.0).run(prompt: "test", workingDirectory: work) { _ in }
        }
        check(ProcessInfo.processInfo.systemUptime - start < 3, "Codex timeout promptly returns without blocking the main actor")
        try await assertChildGone("child-pid", "Codex timeout stops descendants holding the output pipe open")
        try fm.removeItem(at: work.appendingPathComponent("child-pid"))
        var lateEvents = 0
        let task = Task { try await CodexCLI(executable: waiting, homeDirectory: home).run(prompt: "test", workingDirectory: work) { _ in lateEvents += 1 } }
        for _ in 0..<100 where !fm.fileExists(atPath: work.appendingPathComponent("child-pid").path) { try await Task.sleep(nanoseconds: 10_000_000) }
        check(fm.fileExists(atPath: work.appendingPathComponent("child-pid").path), "Cancellation fixture started its child")
        task.cancel()
        do { _ = try await task.value; check(false, "Cancelled Codex run must throw") }
        catch is CancellationError { check(true, "Codex cancellation throws CancellationError") }
        let eventCount = lateEvents
        try await Task.sleep(nanoseconds: 50_000_000)
        check(lateEvents == eventCount, "Stopped Codex cannot deliver late UI callbacks")
        try await assertChildGone("child-pid", "Codex Stop waits for its owned descendant to end")
        let immediate = Task { try await runner.run(prompt: "must not launch", workingDirectory: work) { _ in } }
        immediate.cancel()
        do { _ = try await immediate.value; check(false, "Precancelled Codex run must throw") }
        catch is CancellationError { check(true, "Cancellation before Codex launch performs no work") }
        check(try String(contentsOf: work.appendingPathComponent("prompt.txt"), encoding: .utf8) == "screen off fixture", "Precancelled Codex did not overwrite the fixture prompt")
        let stubborn = try fixture("fake-stubborn", "trap '' TERM\n/bin/cat >/dev/null\nwhile :; do /bin/sleep 1; done")
        let stubbornStart = ProcessInfo.processInfo.systemUptime
        await expectError("time limit") {
            _ = try await CodexCLI(executable: stubborn, homeDirectory: home, timeout: 0.1).run(prompt: "test", workingDirectory: work) { _ in }
        }
        check(ProcessInfo.processInfo.systemUptime - stubbornStart < 2, "Codex escalates SIGTERM-resistant groups to SIGKILL")
        let exiting = try fixture("fake-exiting", "/bin/cat >/dev/null\n/bin/sleep 10 &\nprintf '%s' \"$!\" > success-child-pid\n\(end)")
        let exitingResult = try await CodexCLI(executable: exiting, homeDirectory: home).run(prompt: "test", workingDirectory: work) { _ in }
        check(exitingResult.exitCode == 0, "Successful Codex parent exit keeps its success status during group cleanup")
        try await assertChildGone("success-child-pid", "Successful Codex exit also cleans up owned background children")
        let flooding = try fixture("fake-flood", "/bin/cat >/dev/null\n/usr/bin/yes malformed")
        let floodStart = ProcessInfo.processInfo.systemUptime
        await expectError("time limit") {
            _ = try await CodexCLI(executable: flooding, homeDirectory: home, timeout: 0.1).run(prompt: "test", workingDirectory: work) { _ in }
        }
        check(ProcessInfo.processInfo.systemUptime - floodStart < 2, "Flooded Codex stdout cannot starve timeout and group cleanup")
    }
}
