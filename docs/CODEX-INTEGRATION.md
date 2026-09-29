# Codex Full Control integration

Verified locally on 22 September 2026. Quick Dictate delegates Full Control requests to the user's **primary Codex CLI**, including Codex's existing Computer Use tools. It does not need a separate mouse, keyboard, screenshot, or accessibility bridge. No `QuickDictateComputer` helper was created.

## Verified installation and execution

- CLI version: `codex-cli 0.153.4` from both the npm installation and the desktop app.
- Native desktop executable on this machine: `/Applications/ChatGPT.app/Contents/Resources/codex`. The app is currently named ChatGPT; searching only for `Codex.app` misses this installed binary.
- npm executable: the `codex` executable on your PATH (for example an npm global install).
- Primary configuration/authentication home: `~/.codex`. The app pins `CODEX_HOME` to it and never uses another Codex home or account.
- The runner sends the request through stdin, reads JSONL events, and launches the executable directly rather than evaluating a shell command.

The current execution contract is equivalent to:

```sh
codex exec --json --ephemeral --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox \
  -m gpt-6-astra -c 'model_reasoning_effort="medium"' \
  -C /chosen/working/folder -
```

Full Control is explicitly enabled by the user. The folder is a starting directory, not a filesystem sandbox. Each request remains scoped to what the user asked. Terminal approval bypass does not override macOS privacy permissions or Computer Use's app-access policy. Quick Dictate keeps the request and replies in memory; `--ephemeral` asks Codex not to persist its session files. This is not a claim about provider-side retention. [Official non-interactive mode documentation](https://learn.chatgpt.com/docs/non-interactive-mode).

The parent implementation ran a primary-account CLI smoke test with this model and effort. It actually invoked `mcp__cua_repl.js` and `cua.getApp` for Quick Dictate, which returned the app's Ready interface. Reported end-to-end time was **21.84 seconds**. This establishes that the installed Computer Use runtime works from `codex exec` here; public documentation alone does not establish every standalone CLI installation has that runtime.

## Existing Computer Use runtime

The enabled local plugin is `unified-computer-use@openai-bundled`, version `26.901.51231`. Its manifest is at:

```text
~/.codex/plugins/cache/openai-bundled/unified-computer-use/<version>/.mcp.json
```

The manifest supplies `cua_repl` with `js` and `js_reset`. It launches the desktop app's bundled Node runtime and the plugin's `scripts/launch.mjs`; that script starts the trusted `node_repl` executable. Native interaction uses the existing Codex Computer Use service at `~/.codex/computer-use/Codex Computer Use.app`. Browser and computer surfaces are enabled in this installation. These versioned paths are discovery evidence, not paths to hardcode into Quick Dictate.

The runner should inherit the primary Codex configuration, which already contains the installed plugin, rather than use `--ignore-user-config`, duplicate its MCP manifest, or copy its authentication. A cleaned child environment may omit unrelated credentials while retaining the primary home and executable/runtime paths. Do not pass the parent's active thread identity to a new standalone request.

Computer Use supports app selection, current UI state, screenshots, and interactions through its supplied API. The model must read the tool's returned instructions and current state before acting. Prefer dedicated connectors or command-line tools when they fit the task. Missing permissions must be reported through the normal Codex/macOS flow. Do not synthesize clicks to approve permission dialogs. [Official Computer Use setup and permissions](https://learn.chatgpt.com/docs/computer-use).

## Per-request screen-control switch

When screen control is enabled, load the user's existing tools and instruct the agent to use Computer Use only when needed for the request. Do not silently enable disabled global plugins or alter saved app approvals.

When screen control is disabled, apply invocation-only overrides for the known UI plugins and native surfaces:

```sh
-c plugins.unified-computer-use@openai-bundled.enabled=false \
-c plugins.computer-use@openai-bundled.enabled=false \
-c plugins.browser@openai-bundled.enabled=false \
-c plugins.chrome@openai-bundled.enabled=false \
--disable computer_use \
--disable browser_use \
--disable browser_use_external \
--disable in_app_browser
```

The actual argv element after each `-c` must contain the unquoted dotted key shown above. **Do not insert literal quotes around the plugin ID.** Although saved TOML uses `[plugins."name@marketplace"]`, CLI 0.153.4 handles its dotted override keys differently:

| Override checked with `codex mcp list --json` | Observed result |
| --- | --- |
| `plugins."unified-computer-use@openai-bundled".enabled=false` | Exit 0, but `cua_repl` remains enabled |
| `plugins.unified-computer-use@openai-bundled.enabled=false` | Exit 0; `cua_repl` is absent |

Shell quotes wrapping an entire argument are fine; they must not become literal quote characters within the key passed to `Process.arguments`.

This installation also has a separately configured legacy `node_repl` server that can expose UI functionality and a disabled `computer-use` server. When those top-level servers actually exist, add:

```sh
-c mcp_servers.node_repl.enabled=false \
-c mcp_servers.computer-use.enabled=false
```

Do not blindly create a new top-level MCP table containing only `enabled=false`: a missing server transport can fail configuration loading. Read the existing server inventory first, and disable configured aliases such as `cua_repl` if a user has independently defined them. No screen reading is needed for this discovery. Plugin-level disabling removes the plugin's server automatically. Official configuration documents plugin and MCP enablement flags; the literal-key behavior above was verified against this installed CLI. [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

With the four plugin overrides, four feature disables, and the two existing legacy-server overrides, the local read-only inventory returned exit 0, no `cua_repl`, and `enabled: false` for `node_repl` and `computer-use`. Other unrelated MCP servers remained present. No global configuration was changed. `--strict-config` is not supported by `codex mcp` in this version.

Also tell the agent that screen control is disabled: no screenshots, app accessibility inspection, clicks, typing, scrolling, browser automation, or alternative UI automation through shell tools. Opening a specifically requested app or URL may remain available according to the product's switch semantics. Because Full Control deliberately retains unsandboxed shell execution, this is a tool-exposure and instruction boundary, not an operating-system prohibition against every possible automation program.

## Lifecycle and verification

- Stop must terminate the request's process group, including descendants, and discard subsequent events using the request identity. Do not kill other Codex tasks or the shared Computer Use service.
- Present real CLI progress and tool results. A completed `cua.getApp` smoke test does not establish that an unrelated app is approved or that every future action succeeds.
- Screen-off tests should inspect the resolved tool inventory, in addition to testing the exact argv and prompt. Settings must not rely on the prompt alone to hide known UI tools.
- Keep failures actionable: missing CLI, primary login required, Computer Use unavailable, app permission denied, cancellation, and malformed/incomplete JSONL should remain distinguishable.
- Repeat the bounded Quick Dictate UI probe after runtime upgrades; avoid broad screenshots or unrelated app inspection as a startup check.
