# AIProxySwift surface used by the realtime core

> Everything the realtime lifecycle + tool engine touches in the `AIProxy` SDK, so the new
> repo can either depend on AIProxySwift or **replace it with a raw `URLSession` WebSocket**
> (BYOK). Cited to `OpenAIRealtimeSample/RealtimeManager.swift`. Confidence: **high** (read
> directly from call sites); the SDK's own type *internals* are inferred from usage (med).

## Service construction
| Call | Purpose | Source |
|---|---|---|
| `AIProxy.openAIService(partialKey:serviceURL:)` | Proxied OpenAI service (key split: partial in-app, rest at proxy) | `:189-192` |
| `AIProxy.openAIDirectService(unprotectedAPIKey:)` | **BYOK** direct-to-OpenAI (don't ship in a real app) | `:194-195` |
| `service.realtimeSession(model:configuration:logLevel:) async throws -> OpenAIRealtimeSession` | Open the realtime WS session | `:266-270` |

## `OpenAIRealtimeSessionConfiguration` (init params used)
`inputAudioFormat: .pcm16` · `inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe")` ·
`instructions: String` · `maxResponseOutputTokens: .int(4096)` · `outputModalities: [.audio]` ·
`outputAudioFormat: .pcm16` · `tools: [Tool]` · `toolChoice: .auto` ·
`turnDetection: .semanticVAD(.init(createResponse:eagerness:.auto, interruptResponse:))` ·
`voice: .builtin(String)`  — Source `:229-264`.

- `OpenAIRealtimeSessionConfiguration.Tool` → `.function(.init(name:description:parameters:))`,
  `parameters: [String: AIProxyJSONValue]` (a JSON-Schema dict). Source `:1338-1431`.
- `AIProxyJSONValue` is `ExpressibleByDictionaryLiteral`/`ArrayLiteral`/`StringLiteral`; explicit
  cases used: `.string(_)`, `.array([_])`, `.object([:])`. Source `:1138-1336`.

## `OpenAIRealtimeSession`
| Member | Notes | Source |
|---|---|---|
| `.receiver` | `AsyncSequence` of inbound events (`for await message in session.receiver`) | `:304` |
| `.sendMessage(_:) async` | Send any outbound message struct | many |
| `.disconnect()` | Tear down the WS | `:282, :413` |

**Outbound message types**
- `OpenAIRealtimeInputAudioBufferAppend(audio: String /*base64 pcm16*/)` — `:295-297`
- `OpenAIRealtimeResponseCreate()` — the turn trigger (exactly 4 sites)
- `OpenAIRealtimeConversationItemCreate(item:)` where item is:
  - `.functionCallOutput(callID: String, output: String)` — `:803, :836`
  - `.init(role: String /* "user" | "system" */, text: String)` — `:540, :564, :812`

**Inbound receiver enum cases consumed** (Source `:308-394`)
`.error(OpenAIRealtimeErrorEvent)` · `.sessionUpdated` · `.responseAudioDelta(event)` ·
`.responseTranscriptDelta(event)` · `.responseTranscriptDone(event)` ·
`.inputAudioTranscriptionDelta(event)` · `.inputAudioTranscriptionCompleted(event)` ·
`.inputAudioBufferSpeechStarted` · `.responseFunctionCallArgumentsDone(event)` ·
`.responseCreated` · `.responseDone` · (others → `default`)

**Inbound event payload fields used**
- `OpenAIRealtimeResponseFunctionCallArgumentsDoneEvent`: `.name`, `.arguments` (JSON string), `.callID` — `:371-375, :584`
- audio delta: `.base64Audio` — `:339-340`
- transcript events: `.delta`, `.transcript` — `:349-355`
- `OpenAIRealtimeErrorEvent`: `.errorBody` (`String?`) — `:318, :448`

## Audio (SDK-provided — NOT defined in this repo)
> `AudioController` is **not** in the app source (grep `class AudioController` → 0 hits); it's an
> AIProxySwift helper around AVAudioEngine + VoiceProcessingIO. A BYOK repo must reimplement it.

| Call | Notes | Source |
|---|---|---|
| `AudioController(modes:[.playback,.record], useManualEchoCancellation:) async throws` | Builds ONE VoiceProcessingIO (VPIO) unit | `:204-207` |
| `.micStream() throws -> AsyncStream<AVAudioPCMBuffer>` | Outbound mic frames | `:208` |
| `.playPCM16Audio(base64String:)` | Enqueue TTS playback | `:340` |
| `.interruptPlayback()` | Barge-in: cut current playback | `:367` |
| `.stop()` | Tear down audio (do this BEFORE building a new unit) | `:281, :412` |

## Misc AIProxy helpers
- `AIProxy.base64EncodeAudioPCMBuffer(from:) -> String?` — `:294`
- `AIProxy.request(partialKey:serviceURL:proxyPath:body:verb:headers:) async throws -> URLRequest` — `:889-896`
- `AIProxy.session().data(for:) async throws -> (Data, URLResponse)` — `:897`

## Model + voices (verify before shipping)
- Model string: **`"gpt-realtime-2"`** (`:267`) — ⚠️ the new repo must confirm the latest GA
  realtime model via live docs (worker F / `06-openai-realtime-api.md`).
- GA voices referenced: `"cedar"`, `"marin"` (`:260-263`); voice comes from `personality.voiceName`.

## Replace-with-raw-WebSocket notes
A BYOK build can drop AIProxySwift entirely:
- `realtimeSession` → `URLSessionWebSocketTask` to `wss://api.openai.com/v1/realtime?model=…` with
  `Authorization: Bearer <user key>` + `OpenAI-Beta: realtime=v1` headers.
- Config struct → a `session.update` JSON event sent on connect.
- Outbound structs → `input_audio_buffer.append`, `response.create`, `conversation.item.create` JSON.
- `.receiver` → decode inbound JSON `type` strings into your own event enum.
- `AudioController` → AVAudioEngine input tap (mic) + a player node fed PCM16 (TTS), with
  `setVoiceProcessingEnabled(true)` for echo cancellation/barge-in.
