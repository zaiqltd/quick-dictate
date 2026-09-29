# Spoken replies: verified model and transport choices

Verified 22 September 2026. This is a dated ranking snapshot, not a permanent claim that one voice is universally best. Dictation remains `microsoft/mai-transcribe-2`; the answering model is selected separately from speech synthesis.

## Answering and search

The default answering model is [Gemini 3.5 Flash Lite](https://openrouter.ai/google/gemini-3.5-flash-lite), exact ID `google/gemini-3.5-flash-lite`, verified in the public catalog and authenticated production streaming calls. At verification OpenRouter listed $0.30 per million input tokens and $2.50 per million output tokens. Requests use minimal reasoning and latency routing. The app renders visible response tokens only and retains provider tool-call metadata for subsequent rounds.

Gemini can request a public `web_search` when needed. The app then uses OpenRouter's [web search server tool](https://openrouter.ai/docs/guides/features/server-tools/web-search) with Parallel fast, three results and one search use per helper request. The user request permits at most two helper calls. Parallel fast was listed at $0.001 per search, plus model tokens. The helper accepts only provider citation annotations as retrieval evidence; Markdown links written by the model alone are insufficient. Actual query, sources, failures and completion are shown in the app. The live probe returned citation excerpts and server-tool usage; a native UI query also produced clickable official Python sources.

The user explicitly selected Qwen through the existing OpenRouter account for speech. No additional provider key is needed.

## What Artificial Analysis actually ranks

The [Artificial Analysis provider-voice leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard/provider-voice) evaluates each model with provider-selected voices. Its current top three are:

| Rank | Model | Elo ± 95% confidence interval | Samples |
|---|---|---|---|
| 1 | Cartesia Sonic 3.6 | 1272 ±17 | 1,740 |
| 2 | Alibaba Qwen-Audio-3.0-TTS-Plus | 1260 ±17 | 1,438 |
| 3 | Inworld Realtime TTS-2 | 1245 ±18 | 1,229 |

Sonic's lead over Qwen is 12 Elo points and their confidence intervals overlap. That supports describing Sonic as the current leader on this board, rather than an established large quality gap.

The [controlled-voice leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard/controlled-voice), using the same eight cloned US/UK voices, gives a different ordering:

| Rank | Model | Elo ± 95% confidence interval | Samples |
|---|---|---|---|
| 1 | Inworld Realtime TTS-2 | 1144 ±15 | 2,206 |
| 2 | Cartesia Sonic 3.6 | 1138 ±15 | 2,215 |
| 3 | Alibaba Qwen-Audio-3.0-TTS-Plus | 1121 ±16 | 1,983 |

The [AA model comparison](https://artificialanalysis.ai/text-to-speech/models) also reports generation speed in characters per second. That measures throughput, which is different from delay until speech begins. I did not establish a current AA first-audio-latency value for these three models from its public pages, so no startup-latency winner is claimed here.

## Practical choice available through the existing account

The live [OpenRouter speech model catalog](https://openrouter.ai/api/v1/models?output_modalities=speech) listed 18 speech models when checked. It includes Qwen Plus and does not include Cartesia/Sonic. Qwen Plus is therefore the highest-ranked currently available choice on the provider-voice board using the app's existing OpenRouter access; it is not the literal #1 model on either AA board.

- Exact model: `qwen/qwen-audio-3.0-tts-plus` (catalog canonical snapshot `qwen/qwen-audio-3.0-tts-plus-20260723`).
- Default voice: `longanlingxin`, described by Alibaba as warm/empathetic female; `longanlufeng` is bright/cheerful male. Both support English and Mandarin in the [official voice list](https://help.aliyun.com/en/model-studio/qwen-audio-tts-voice-list).
- [OpenRouter pricing](https://openrouter.ai/qwen/qwen-audio-3.0-tts-plus): $20 per million input characters at verification. AA's $27.60 figure is creator pricing and is not the same route's price.
- OpenRouter's model page showed median latency 0.53 seconds. That is OpenRouter's displayed aggregate metric, not a latency measurement made by this app or by AA.

If the user wants Sonic specifically later, [Cartesia's current model documentation](https://docs.cartesia.ai/build-with-cartesia/tts-models/latest) identifies `sonic-3.6`, with fixed snapshot `sonic-3.6-2026-08-27`. That requires separate Cartesia authentication. Its [SSE endpoint](https://docs.cartesia.ai/api-reference/tts/sse) streams base64 audio chunks from `POST https://api.cartesia.ai/tts/sse` with bearer authentication and `Cartesia-Version: 2026-08-14`. The app does not silently substitute or claim to use Sonic.

## Implemented OpenRouter request and audio contract

[OpenRouter TTS documentation](https://openrouter.ai/docs/guides/overview/multimodal/tts) documents `POST https://openrouter.ai/api/v1/audio/speech`, bearer authentication, and binary audio streaming. The [official OpenAPI schema](https://openrouter.ai/openapi.json) specifies PCM as signed 16-bit little-endian. Neither establishes a universal sample rate, so the client reads it from response metadata.

```json
{
  "model": "qwen/qwen-audio-3.0-tts-plus",
  "input": "The current assistant reply.",
  "voice": "longanlingxin",
  "response_format": "pcm"
}
```

The integration agent's authenticated synthetic smoke succeeded with HTTP 200 and `Content-Type: audio/pcm;rate=24000;channels=1`. It received 180,480 bytes (3.76 seconds of mono audio). First 256 bytes arrived after 1.900 seconds and completion after 2.977 seconds for an 11-word fixture. This single cold-request observation is not a general latency guarantee. A WAV-format request was rejected with HTTP 400; the documented supported formats are PCM and MP3. No user recording was used in these speech tests.

`CloudSpeech.swift` uses the response's rate/channel metadata, rejects unknown formats or missing rate, and decodes complete frames across arbitrarily split network chunks. Production has no guessed rate fallback. The client emits 1,024-frame blocks. Native playback starts with at least 80 milliseconds queued (or the complete shorter reply) and limits queued audio to approximately two seconds using back-pressure. It does not wait for the entire response before playing.

The request is limited to 6,000 characters, 25 seconds without network progress, a 60-second URLSession resource timeout and 180 seconds of returned audio. Keys enter at runtime, only in the authorization header; speech sends the current reply text, not microphone audio or conversation history. No voice files are written. HTTP/provider errors use fixed user-facing text rather than exposing response bodies.

`SpeechOutput` reports `preparing` while waiting for audio and `speaking` only when the audio sink starts. Stop cancels the streaming request and queued native audio. Generation checks reject late callbacks and prevent an old request from stopping a replacement. The client and playback sink are injectable, allowing HTTP, frame decoding, timing, cancellation, and state tests without credentials, network access or sound output. Physical listening/device-switch quality remains a separate live verification step.

The next utterance is prefetched while the current one plays, with one bounded in-memory cache. Long answers are split without dropping their endings. In a two-sentence live run, the first playback finished at 11.235 seconds and the second began at 11.262 seconds: approximately 27 ms between chunks. A complete synthetic audio → MAI → Gemini → Qwen run started playback in 3.652 seconds; an earlier cold run took 6.369 seconds. These single observations are recorded in [QA.md](QA.md), not presented as a general latency guarantee.
