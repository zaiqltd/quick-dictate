# Quick Dictate

Open source from [ZAIQ](https://zaiq.ai), a South African AI engineering company. MIT licence.

A native Mac voice app with simple dictation, message polishing and optional assistant modes. **Hold Option + Command → speak → release → text.** No Space or Control key is needed. Dictation is on by default; Polish, Ask, Do and Full Control are optional switches in Settings. The installed copy preserves your enabled modes through updates.

With the default dictation shortcut, recording begins while both keys are held and finishes when either is released. Another key cancels and discards the pending dictation, except when it selects an enabled assistant shortcut. Switching to an assistant shortcut routes that recording to the selected mode, without pasting it as dictation.

Installed at `/Applications/Quick Dictate.app`. Open it from Applications, Spotlight or the Dock. Its Dock icon and waveform menu-bar control stay available when you close the window; click either to bring Quick Dictate back. Closing the window keeps hold-to-talk running, while **Quick Dictate → Quit Quick Dictate** exits the app.

## Quick start on a new Mac (build from source)

You need macOS 14 or newer (Apple Silicon or Intel), Apple's command line tools and your own OpenRouter API key from https://openrouter.ai/settings/keys. This repository contains no API key.

1. Install the command line tools once: `xcode-select --install`
2. Clone this repository and open its folder in Terminal.
3. Run `./scripts/test.sh` (the automated checks), then `./scripts/install.sh`. The install script builds the app, copies it to `/Applications/Quick Dictate.app` and opens it. If an older copy is there it is kept, not deleted, in `~/Library/Application Support/Quick Dictate/previous-apps/`.
4. In Quick Dictate, open **Settings**, paste your OpenRouter key and click **Save key**. It is stored in your Mac's Keychain, never in the project.
5. Allow **Microphone**, then allow Quick Dictate under System Settings → Privacy & Security → **Accessibility** (for the global shortcut and automatic paste).
6. Click any text field, hold **Option + Command**, speak, and release.

To change the code, edit the files in `Sources/` and run `./scripts/install.sh` again (quit the app first). `AGENTS.md` is the design brief for coding agents and describes how each mode must behave. `./scripts/build.sh` builds without installing; `./scripts/package.sh` makes a shareable universal ZIP in Downloads.

Full Control is off by default. It needs your own signed-in Codex CLI and can run commands on your Mac without asking, so only turn it on if that is what you want.

## First use

1. Open Quick Dictate. It uses the OpenRouter key saved in **Settings** (your Keychain). If you keep `OPENROUTER_API_KEY` in `~/.credentials/openrouter.env`, that is used as a fallback.
2. Click **Microphone** and allow microphone access.
3. Click **Shortcut & paste**, then enable **Quick Dictate** under System Settings → Privacy & Security → Accessibility. This enables the global modifier-only shortcut and lets the app send Command-V. The main-window hold-to-talk button works without Accessibility.
4. Click a text field in any app. Hold **Option + Command** together while speaking, then release.

A tiny bottom pill shows the live audio level and recording time. Release the keys to finish; its × button cancels. It disappears shortly after the result returns. The result is copied to the clipboard and pasted into the original text field if it is still focused. If you switch apps or fields while the request is processing, the result stays copied; press Command-V wherever you want it. The app never presses Return or sends a message.

With Dictate selected, you can also press and hold the **Hold to talk** card in the main window with the mouse, then release to transcribe and copy. For direct insertion into another app, use the global shortcut from that app.

## Remember a correction

Select a misheard word in the latest transcript, click **Correct & remember**, enter the right spelling and click **Remember**. You can also open the correction without selecting and fill in both fields. It corrects matching words in the latest transcript and copies the corrected text; paste it where needed. Text already inserted into another app is not edited automatically.

Future dictations include the preferred spelling as a vocabulary hint for MAI-Transcribe-2. This helps names and unusual words; it is not a guarantee or model retraining. There is no extra model call. Only words you explicitly save are remembered; edits in other apps are not monitored.

Open **Settings → Remembered words** (also in the menu-bar menu) to add a name directly, **Forget** a word, or **Undo** the last dictionary change. The dictionary holds up to 100 words or short phrases. Undo is available during the current app session and changes the dictionary, not text already copied or pasted.

The dictation shortcut keeps working while settings or a dictionary window is open. If you dictate again while a correction is open, that correction still applies to the transcript you originally opened.

## Assistant modes

**Polish** turns rambling speech or rough text into a clearer message while keeping your meaning and tone. Enable it in Settings, then hold **Option + Command + P**, speak, and release. MAI transcribes, GPT-6 Luna removes filler/repetition and improves wording, and the result follows your normal paste/copy setting without pressing Send. A Polishing indicator, elapsed timer and Cancel remain visible while it works. This adds one rewrite request through OpenRouter.

You can also type or paste a message into the Polish tab and choose **Polish text**; typed results appear there for explicit copying. Open **Original message → Copy original** to recover what you said. Both versions stay in memory until replaced or the app quits. A failed rewrite preserves the original and offers Try again; it never silently pastes the unpolished text. Retry copies a voice result instead of pasting into an old field. Polish rewrites questions and commands without answering or running them, and has no search, voice reply or assistant conversation. Ordinary Dictate still uses only MAI.

Open **Settings → Make it yours** and enable only what you want. Each enabled mode gets a tab and its own hold-to-talk shortcut. You can also type a request in the assistant panel.

| Mode | Default shortcut | What happens when you release |
| --- | --- | --- |
| Dictate | **⌥⌘** | Transcribes and copies/pastes your words. |
| Polish | **⌥⌘P** | Transcribes, cleans up the message and copies/pastes the result. |
| Ask | **⌥⌘A** | Transcribes your question, streams an answer and speaks it back. |
| Do | **⌥⌘R** | Transcribes your request and proposes steps using the capabilities you enabled. |
| Full Control | **⌥⌘F** | Sends the task to Codex Astra Medium with full access and no command approvals. |

Hold the full shortcut while talking; release to finish. Settings offers alternate preset keys and rejects duplicate shortcuts across enabled modes. Keyed shortcuts use the labelled physical key positions. Existing system or app shortcuts can still conflict; choose another preset if needed.

**Ask** answers questions and can search the public web when needed; it has no local computer actions. **Do** adds two separate switches, both off by default: **Terminal commands** and **Open apps, files & websites**. Enabling Do alone does not enable either capability.

**Full Control** hands the task to the installed **Codex CLI**, using **GPT-6 Astra with medium reasoning** and your primary saved Codex login. It can build projects, change files, run commands, open apps and websites, and use Codex's built-in **Computer Use/browser tools** when needed. The separate screen-control switch is on by default for this mode. Codex's app-access controls and macOS privacy permissions still apply; no custom screen-control bridge is installed. Full Control bypasses command approval prompts and filesystem sandboxing, as requested. The working folder is a starting point, not a restriction on access.

Codex's public updates, current commands, command results, changed paths and tool activity appear as it works. **Stop** terminates that request's CLI process group; completed changes remain, and deliberately detached processes can escape it. A request has a 30-minute limit. Voice requests use MAI for transcription and speak the final Codex answer with Qwen; typed tasks remain silent unless you choose Speak. Speaking again can start a follow-up after the current task finishes, or interrupt it with a new request. Replay never runs the task again.

Full Control starts ephemeral Codex runs with bounded context from this conversation. Switching between Full Control and Ask/Do clears the conversation, so local Codex results are not silently forwarded to another provider. It always uses your default Codex account (`~/.codex`). You can disable Full Control or its screen-control tools independently. The screen switch removes known UI tools and instructs Codex not to use alternate UI automation; it is not an OS sandbox around full terminal access. [Verified CLI and built-in Computer Use integration](docs/CODEX-INTEGRATION.md).

The default **Ask/Do** answering model is **GPT-6 Luna** (`openai/gpt-6-luna`) through OpenRouter. Haiku, Sonnet and Opus remain selectable in Settings. Answers stream into the panel. Dictation continues to use MAI-Transcribe-2 directly, without a rewriting model. Assistant tokens, web searches and cloud speech have separate OpenRouter charges. Full Control's agent uses your Codex account; its transcription and optional speech still use OpenRouter.

While a request is working, a visible progress card shows the current step, elapsed time and **Stop**. It appears before the first answer token and updates for search, incoming text, reviewed actions and voice preparation/playback. After 12 seconds without new data, remote waits show an amber message with the time since the last update; this reports a wait, not proof of a failed connection. The navigation also times microphone/transcription stages. Search and action follow-ups keep the original request timer, while Speak replay starts a new timer. Full activity history remains expandable.

**Speak voice replies** is on by default. Spoken assistant requests are answered aloud using **Qwen-Audio-3.0-TTS-Plus** through OpenRouter; typed requests stay quiet unless you click **Speak**. Completed sentences can begin playing while the rest of an answer arrives. **Stop** interrupts the current request and speech; starting another recording stops old playback and prevents its remaining response from autoplaying. **Speak** replays only the last answer through TTS, without rerunning its question, searches or actions. A speech failure leaves the written answer available and can be retried with Speak.

Qwen ranked **#2 on Artificial Analysis's provider-voice board and #3 on its controlled-voice board** when checked on 22 September 2026. It was the highest-ranked OpenRouter-available option on the provider-voice board; that board's leader, Cartesia Sonic 3.6, requires separate authentication. These are dated rankings, not a universal quality guarantee. See [VOICE-RESEARCH.md](docs/VOICE-RESEARCH.md) for sources, pricing, voice selection and transport evidence.

**Search when needed** is also on by default. The assistant can make up to two public-web queries per request through **Parallel fast via OpenRouter**, when facts need checking or you ask it to search. This read-only search runs without a local-action Run dialog. The interface shows **Searching**, the actual query, returned source links and an activity history; it does not show a successful search when retrieval fails. You can switch search and spoken replies off independently in Settings. Existing Gemini selections upgrade to Luna; other model choices, mode switches, shortcuts and working folder persist.

**Include selected text** remains off by default. When enabled, it captures up to 6,000 characters at the start of an assistant hold, skipping secure fields. It does not continuously read selections or the clipboard, and typed requests do not automatically capture selected text.

Assistant conversations stay in memory. **Copy answer** copies the latest reply; **New chat** clears the current conversation. Closing the window keeps the app and conversation running; quitting clears it. There is no saved conversation database or permanent assistant memory.

### Reviewed local actions

In **Do**, every proposed local action shows its exact command or destination and chosen working folder. Do actions run only after you click **Run**. **Cancel** declines the pending request; **Stop** interrupts an active request or command. Multiple actions are reviewed separately, and a request has a bounded number of assistant rounds. Full Control is the separate mode that executes directly.

Terminal commands start in the folder you choose in Settings. **They run with your Mac user's privileges; the working folder is not a sandbox.** A command can access or change anything those privileges permit, so review its full text. Ordinary file-open actions must resolve inside the chosen folder; obvious credential, private-key and account-configuration paths are rejected. Apps can be opened from `/Applications` or `/System/Applications`, and website actions accept HTTP/HTTPS URLs.

A terminal command has a **45-second limit** and a **32 KB output cap**. Live output appears in the panel, and the reviewed action's result goes to the selected model through OpenRouter so it can explain the outcome. The runner drains output even after the display cap, closes interactive input, uses a minimal environment without inherited API tokens, and stops its process group on cancellation, timeout or completion. Programs that deliberately detach can escape a process group. Stopping does not undo completed changes, and a request already received by OpenRouter may still be charged.

Ask and Do cannot click your interface, read your screen or inspect your open browser tabs. Full Control can use Codex's built-in tools for that when enabled and needed. Quick Dictate does not continuously watch the screen, record ordinary typing, monitor edits in other apps, or collect clipboard history.

## Kept deliberately small

- Compact 400 × 320 base dictation window, one hold-to-talk control, and one latest-transcript box. Enabled mode tabs, assistant chat, settings and errors add space when needed.
- Tiny 156 × 32 recording pill, about 81% less area than the original.
- Direct OpenRouter → `microsoft/mai-transcribe-2`. No extra rewriting model or model fallback.
- Automatic language detection and the model's standard punctuation. Spoken fillers may remain.
- A failed transcription keeps its audio in memory for **Retry**. Dictation retries copy without switching apps; assistant retries return to their original enabled mode. Turning that mode off clears its pending audio.
- **Cancel** stops recording or the request and clears the pending audio. A request already received by OpenRouter may still incur its normal charge.
- Five-minute recording limit; it stops and transcribes at that limit.
- Settings: replace the key, control automatic paste/login startup, choose shortcuts, and opt into assistant features individually.
- Microphone follows the Mac's selected default sound input.

The app needs an internet connection. [OpenRouter lists MAI-Transcribe-2 at US$0.10 per audio hour](https://openrouter.ai/microsoft/mai-transcribe-2), checked 22 September 2026. Usage is billed to the existing OpenRouter account.

## Data and credentials

In Full Control, your request and enabled selected-text context go to Codex using your primary login. Codex's tools may read task-relevant files and screen/browser content and send that context to its model. The CLI uses ephemeral sessions; this does not change the provider's retention policy. The app does not read or copy Codex login tokens. Full Control's final reply is also sent to Qwen through OpenRouter if spoken output is requested.

Recorded audio goes only to OpenRouter's transcription endpoint and its MAI provider. In Ask or Do, the resulting request text goes to the selected assistant model through OpenRouter; enabled selected-text context and reviewed action results are also sent. When used, generated public-web queries go to Parallel through OpenRouter. Cloud speech sends the current reply text to Qwen through OpenRouter, rather than microphone audio or the full conversation; streamed audio is played in memory without saving voice files. The app records only while you hold the shortcut or button (or explicitly use its accessibility start/finish actions). Its temporary WAV is removed after stop/cancel; pending retry audio stays in memory until a new recording, cancellation, success, or quitting. After an unexpected exit, leftover app-owned temporary recordings are cleaned on the next launch. There is no local transcript database or telemetry. The latest transcript stays in the window until quit, and copied text remains in the Mac clipboard until replaced.

Explicitly remembered spellings and their misheard forms are saved locally in `~/Library/Application Support/Quick Dictate/dictionary.json`, with access limited to your Mac account. Only the preferred spellings are sent with future audio as hints. No complete transcripts are stored in that file. A damaged dictionary is preserved, and dictation continues without its hints.

API keys entered in Settings go to the macOS Keychain. If no app-specific Keychain key is present, the app reads only `OPENROUTER_API_KEY` from `~/.credentials/openrouter.env`. It does not execute that file, change its model setting, or embed credentials in the app.

## Build and maintain

Building from source here uses an Apple Silicon Mac, macOS 14 or later, and Apple's Command Line Tools / Xcode. The shared ZIP supports Apple Silicon and Intel Macs running macOS 14 or later. The app has no third-party package dependencies. Optional Full Control requires an installed, signed-in Codex CLI and uses its existing tools; its child process runs only while a task is active.

To share the app with another Mac user, run `./scripts/package.sh`. It creates a universal Apple Silicon/Intel ZIP in Downloads with [friend setup instructions](docs/SHARE-SETUP.txt). The package contains only the app and those instructions; each person enters their own OpenRouter key in Settings. This personal build is ad-hoc signed, not Developer ID signed or notarized, so macOS may require its documented **Open Anyway** step on the other Mac.

```sh
cd quick-dictate
./scripts/test.sh
./scripts/test-tabs.sh
./scripts/build.sh
# Quit Quick Dictate before installing an update.
./scripts/install.sh
```

The native tab checks use an isolated off-screen window in a logged-in Mac session. They exercise clicks across each tab without sending global mouse events, recording audio or making requests.

The install script archives a previous app under `~/work/_ARCHIVE/` and records its restoration path in `_OPS/CHANGELOG.md`. The app is locally ad-hoc signed with a stable bundle identifier; it is not notarized for distribution. A macOS update or signing change can require granting Accessibility again.

For an explicit audio-file smoke test through the same production client:

```sh
"/Applications/Quick Dictate.app/Contents/MacOS/QuickDictate" --transcribe-file /path/to/test.wav
```

That command uploads the specified file with your saved vocabulary hints and prints the transcript, duration, API cost, and request time. Supported file formats are WAV, MP3, and FLAC. The recorder uses 16 kHz, 16-bit mono WAV because this exact path was verified against MAI-Transcribe-2; M4A was rejected by its provider despite appearing in the general OpenRouter format list.

See [VOICE-RESEARCH.md](docs/VOICE-RESEARCH.md) for cloud speech evidence, and [AGENT-RESEARCH.md](docs/AGENT-RESEARCH.md) for earlier assistant integration research. An implemented feature or software event test is not evidence that a physical shortcut or live interface flow has been exercised.


Hands-free dictation: with Control as the Dictate shortcut, double-tap Control to lock recording on, then tap Control once to finish and transcribe. Escape cancels. Ordinary Control holds and the other mode shortcuts still work. The first tap must be brief (up to 220 ms), followed by the second press within 350 ms; typing between taps cancels the gesture. Recording remains limited to five minutes.

## Licence

MIT. See [LICENSE](LICENSE). Bring your own OpenRouter key; none is included, and usage is billed to your OpenRouter account.
