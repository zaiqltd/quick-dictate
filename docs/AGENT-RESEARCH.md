# Optional assistant integration — 22 September 2026

The user's 22 September request expands Quick Dictate to optional voice chat and local actions. Dictation still uses MAI-Transcribe-2 directly, without rewriting. The assistant is a separate OpenRouter chat-completions client; it does not execute actions itself.

## Verified models

Verified using the public `https://openrouter.ai/api/v1/models` catalog and official model pages on 22 September 2026. Prices are USD per million input / output tokens and may change.

| Setting | Exact model ID | Input / output | Primary source |
| --- | --- | --- | --- |
| Fast | `anthropic/claude-haiku-4.5` | $1 / $5 | [OpenRouter](https://openrouter.ai/anthropic/claude-haiku-4.5) |
| Balanced (default) | `anthropic/claude-sonnet-5` | $2 / $10 | [OpenRouter](https://openrouter.ai/anthropic/claude-sonnet-5) |
| Powerful | `anthropic/claude-opus-5` | $5 / $25 | [OpenRouter](https://openrouter.ai/anthropic/claude-opus-5) |

All three advertise tools/tool choice. Sonnet 5 does not advertise temperature, so the client omits it. Model catalog existence is not an authenticated live success test; that evidence belongs in QA after the app is exercised.

## API and execution boundary

Native `URLSession` posts to `https://openrouter.ai/api/v1/chat/completions`; no SDK or backend is needed. The request supplies messages, a fixed model preset, 4,096 maximum output tokens, nonstream output, and only the caller's enabled tool declarations. Provider routing requests support for parameters and prefers latency. [API reference](https://openrouter.ai/docs/api_reference/overview), [provider routing](https://openrouter.ai/docs/guides/routing/provider-selection).

Tool calls are proposals. The client parses and checks tool IDs, names and JSON arguments, while retaining the full assistant message for the next round, including reasoning metadata. A tool result uses `role: tool` and the original `tool_call_id`; tool declarations remain on follow-up requests. Argument schemas and current user capabilities must also be enforced by the local executor. The client never runs a command or launches an app. [OpenRouter tool calling](https://openrouter.ai/docs/guides/features/tool-calling).

The client bounds conversation/request/response/tool sizes, rejects unknown or duplicate calls, treats truncated output as an error, and sanitizes transport/provider errors. Cancellation remains `CancellationError` so the controller can reliably return to idle. Its tests use an isolated `URLProtocol` without credentials, network spending, microphone or clipboard access.

Optional local spoken replies can use [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer). Stop speaking when a new recording begins to avoid recording the assistant's own answer.

## GitHub assessment

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) is a native Swift package with a shortcut recorder, down/up callbacks, and system/main-menu conflict checks. Standard key registration does not replace the existing modifier-only gesture recognizer. It is [MIT licensed](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/license); copied code must retain its copyright/license notice.
- [OpenCode](https://github.com/anomalyco/opencode) has a mature terminal-agent structure and [explicit action permissions](https://opencode.ai/docs/permissions/). It is [MIT licensed](https://raw.githubusercontent.com/anomalyco/opencode/dev/LICENSE). Embedding the complete runtime would add installation and lifecycle complexity to this small native app; direct OpenRouter integration is the selected approach. No third-party source was copied into AgentClient.

## Execution recommendations

Advertise only enabled capabilities, and re-check them when an action executes. Show exact commands and working directories for review. A working directory is not a sandbox. A terminal runner must use bounded output/timeouts, support cancellation of child processes, and not inherit the app's OpenRouter credential. Keep the dictation and assistant routing separate, avoid ambient clipboard/screen collection, and keep assistant history in memory unless the user deliberately opts into persistence.
