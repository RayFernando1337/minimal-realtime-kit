# 06 — OpenAI Realtime API: current (2026) API truth

> **Worker slice:** the *current* OpenAI GPT Realtime API surface, verified from **live** docs
> (mid-June 2026). This is the "ground truth" a builder agent can rely on for a **minimal,
> open-source, bring-your-own-key iOS (Swift)** voice + tool-calling app.
>
> **Method:** every headline claim is cross-checked against ≥2 sources and tagged
> `[conf: high|med|low]`. OpenAI's own docs (`platform.openai.com/docs`,
> `developers.openai.com`) win over third parties. Conflicts and unverifiable items are called
> out explicitly in **§9 Open questions / unverified**.
>
> **Scope guard:** this file is about the *external API*. The AIProxySwift SDK mapping/BYOK depth
> is owned by worker **07**; I only touch it where Q6 ("what changed vs baseline") requires it.

---

## 0. TL;DR (the 60-second version)

- **`gpt-realtime-2` is real and current.** It is OpenAI's most capable realtime model
  (GPT‑5‑class reasoning, **128K** context, configurable `reasoning.effort`), launched
  **May 7–8, 2026**. The existing app's target is correct, not stale. `[conf: high]`
- Model **family** today: `gpt-realtime` (first GA, Aug 2025) → `gpt-realtime-1.5` →
  **`gpt-realtime-2`** (flagship) + `gpt-realtime-mini` (cheap) + `gpt-realtime-translate` +
  `gpt-realtime-whisper` (streaming STT). All `gpt-4o-realtime-preview*` models were
  **shut down 2026-05-07**. `[conf: high]`
- **Voices:** `alloy, ash, ballad, coral, echo, sage, shimmer, verse, marin, cedar`
  (lowercase). Use **`marin`** or **`cedar`**. Voice is locked once the model emits audio. `[conf: high]`
- **Transport for a native client (iOS): OpenAI recommends WebRTC** over WebSocket for
  "more consistent performance." WebSocket is positioned for server↔server. `[conf: high]`
- **Client auth = ephemeral client secrets.** Backend (or, for BYO-key, the device itself)
  POSTs to **`/v1/realtime/client_secrets`** with the standing key → gets a short-lived
  token `value` that looks like **`ek_…`** (TTL 10–7200s, **default 600s**). Never ship a
  standing key in the client. `[conf: high]`
- **Session config is now nested** under `session.audio.input.*` / `session.audio.output.*`
  with `output_modalities` (not `modalities`). This is the big GA rename vs the old flat
  beta surface. `[conf: high]`
- **Tools:** client-fulfilled `function` tools use the classic
  `response.function_call_arguments.done` → `function_call_output` → `response.create` loop.
  Realtime **also** supports `mcp` tools/connectors executed *by the API*. **There is NO native
  hosted `web_search` tool in Realtime** — do it as a client function (optionally delegating to
  the Responses API's `web_search`). `[conf: med-high]`

---

## 1. Model name(s) & voices

### 1.1 The current model family

| Model string | What it is | Status (Jun 2026) | Key specs |
|---|---|---|---|
| **`gpt-realtime-2`** | Flagship speech-to-speech w/ GPT‑5‑class reasoning | **Current / recommended** | 128K ctx, 32K max output, `reasoning.effort`, parallel tool calls, image input |
| `gpt-realtime-1.5` | Mid-gen GA model; official replacement for the retired previews | Current | (predecessor to `-2`) |
| `gpt-realtime` | **First GA** realtime model (alias) | Current | snapshot `gpt-realtime-2025-08-28`, 32K ctx, 4096 max output |
| `gpt-realtime-mini` | Cost-optimized realtime | Current | replacement for `gpt-4o-mini-realtime-preview` |
| `gpt-realtime-translate` | Live speech→speech translation (70+→13 langs) | Current | $0.034/min |
| `gpt-realtime-whisper` | Streaming STT (transcription sessions only) | Current | $0.017/min; **turn_detection must be `null`** |
| ~~`gpt-4o-realtime-preview*`~~, ~~`gpt-4o-mini-realtime-preview`~~ | Beta/preview gen | **RETIRED 2026-05-07** | → use `gpt-realtime-1.5` / `gpt-realtime-mini` |

- **`gpt-realtime` (GA Aug 28, 2025):** "our most advanced speech-to-speech model yet …
  generally available … starting today," priced 20% below `gpt-4o-realtime-preview`.
  Source: OpenAI blog *Introducing gpt-realtime* (<https://openai.com/index/introducing-gpt-realtime/>)
  + model page (<https://platform.openai.com/docs/models/gpt-realtime>). `[conf: high]`
- **`gpt-realtime-2` (May 7–8, 2026):** "our first voice model with GPT‑5‑class reasoning …
  increasing the context window from 32K to 128K … select from minimal, low, medium, high, and
  xhigh reasoning levels, with low as the default." Released with `gpt-realtime-translate` and
  `gpt-realtime-whisper`. Sources: OpenAI blog *Advancing voice intelligence with new models in
  the API* (<https://openai.com/index/advancing-voice-intelligence-with-new-models-in-the-api/>)
  + model page (<https://developers.openai.com/api/docs/models/gpt-realtime-2>). `[conf: high]`
- **`gpt-realtime-1.5` is real**, not a hallucination: it is the named replacement for the
  retired `gpt-4o-realtime-preview` on OpenAI's deprecations page and appears in the realtime
  client-events model enum (`"gpt-realtime" | "gpt-realtime-1.5" | "gpt-realtime-2" | …`).
  Sources: <https://developers.openai.com/api/docs/deprecations>,
  <https://developers.openai.com/api/reference/resources/realtime/client-events/>. `[conf: high]`

> **Myth-bust:** a secondary blog (zenn.dev) claimed an "April 2026 GA" and a model called
> `gpt-realtime-1.5` as *the* GA name. The **GA was Aug 2025** (`gpt-realtime`); `1.5` is a later
> point release, and the flagship is `gpt-realtime-2`. Treat that blog's timeline as wrong. `[conf: high]`

**Dated snapshots:** `gpt-realtime` → `gpt-realtime-2025-08-28`. For `gpt-realtime-2` the
model page lists the alias but a clean dated snapshot string could not be extracted from the
rendered page — **pin by alias `gpt-realtime-2` and confirm the dated snapshot in the dashboard
before locking.** `[conf: med]` (flagged in §9)

### 1.2 Voices

Current voices (lowercase, case-sensitive): **`alloy, ash, ballad, coral, echo, sage,
shimmer, verse, marin, cedar`**. For best quality OpenAI recommends **`marin`** or **`cedar`**
(new in the Aug 2025 GA). The `voice` **cannot be changed once the model has produced audio** in
a session.
Source: realtime conversations guide
(<https://platform.openai.com/docs/guides/realtime-conversations>) + the
openai-agents-python error message enumerating valid voices (issue #1746). `[conf: high]`

> **Conflict flagged:** Vapi's docs claim `ash, ballad, coral, fable, onyx, nova` are *not*
> supported by realtime models. OpenAI's own guide lists `ash/ballad/coral/sage/verse` as valid;
> `fable/onyx/nova` are simply not in the realtime list. **Trust OpenAI's list above.** `[conf: med-high]`

---

## 2. Transport: WebRTC vs WebSocket (native iOS)

**OpenAI's explicit recommendation:** *"When connecting to a Realtime model from the client
(like a web browser or mobile device), we recommend using WebRTC rather than WebSockets for more
consistent performance."* For audio **output** to client devices, *"we recommend using WebRTC
rather than WebSockets. WebRTC will be more robust sending media … over uncertain network
conditions."*
Source: <https://platform.openai.com/docs/guides/realtime-webrtc>,
<https://platform.openai.com/docs/guides/realtime-conversations>. `[conf: high]`

| | **WebRTC** (OpenAI-recommended for clients) | **WebSocket** (server↔server) |
|---|---|---|
| Media handling | Peer connection does mic capture + remote audio playback + **auto interruption/truncation** for you | You manually `input_audio_buffer.append` base64 PCM (≤15 MB/chunk), `commit`, buffer + play output, and handle `conversation.item.truncate` yourself |
| Endpoint | `POST https://api.openai.com/v1/realtime/calls` (SDP) | `wss://api.openai.com/v1/realtime?model=…` |
| Events channel | WebRTC **data channel** named `oai-events` | the same socket |
| iOS dependency | needs a **Swift WebRTC stack** (Google `WebRTC.xcframework` / LiveKit) — heavyweight | **dependency-free** via `URLSessionWebSocketTask` |
| Best for | production voice on flaky mobile networks | backend bridges (e.g., Twilio/SIP), or a minimal app willing to own audio |

### 2.1 WebRTC connection (two flows)

1. **Ephemeral-token flow (recommended for client apps):**
   - Your backend (or, for BYO-key, the device) mints `ek_…` via `/v1/realtime/client_secrets`.
   - The client `POST`s its **SDP offer** to `https://api.openai.com/v1/realtime/calls` with
     `Authorization: Bearer ek_…` and `Content-Type: application/sdp`; the response body is the
     **SDP answer**.
2. **Unified-interface flow:** the client sends its SDP to *your* server; your server attaches
   the session config + standard key in a multipart form and `POST`s to
   `/v1/realtime/calls`, relaying the SDP answer back. Simpler, but puts your server in the
   session-init path.

There **is** an SDP / `/v1/realtime/calls` flow — confirmed. `[conf: high]`
(See `snippets/api-reference/06-webrtc-connect.swift`.)

### 2.2 WebSocket connection

`wss://api.openai.com/v1/realtime?model=gpt-realtime-2`, with `Authorization: Bearer <ek_… or
key>`. You then drive the session entirely with JSON events and own audio I/O. AIProxySwift
uses this transport. (See `snippets/api-reference/05-websocket-connect.swift`.) `[conf: high]`

---

## 3. Auth / ephemeral client secrets (critical for BYO-key)

**Never ship a standing API key in a client.** The current pattern is **ephemeral client
secrets**:

- **Endpoint:** `POST https://api.openai.com/v1/realtime/client_secrets`
- **Auth on that call:** a **standard** OpenAI API key (`Authorization: Bearer sk-…`).
- **Body:**
  ```jsonc
  {
    "expires_after": { "anchor": "created_at", "seconds": 600 },
    "session": { "type": "realtime", "model": "gpt-realtime-2", "audio": { "output": { "voice": "marin" } } }
  }
  ```
- **TTL (`seconds`):** must be **10–7200** (2 h); **default 600s (10 min)** if omitted.
- **Response** (`ClientSecretCreateResponse`): `{ "value": "ek_…", "expires_at": <unix>, "session": { "id": "sess_…", … } }`.
  The **`value`** (an `ek_…` string) is the token the client uses as `Bearer` to connect.
- **`OpenAI-Safety-Identifier`** header (a stable, hashed user id) should be set on the
  *server-side* mint call; the Realtime API binds it to the token.

Sources: WebRTC guide (<https://platform.openai.com/docs/guides/realtime-webrtc>); client-secrets
API reference
(<https://developers.openai.com/api/reference/python/resources/realtime/subresources/client_secrets/methods/create/>);
`openai-python` `client_secrets.py` ("The client secret is a string that looks like `ek_1234`").
`[conf: high]`

> **Beta→GA note:** in the old beta surface, ephemeral tokens were minted at
> `POST /v1/realtime/sessions`. GA moved this to **`/v1/realtime/client_secrets`**. `[conf: high]`

### 3.1 BYO-key, no-backend reality (open-source app)

An open-source BYO-key app has the user's **own** standing key on-device (in the Keychain). The
honest options, in order of hygiene:

1. **Mint-on-device (recommended):** use the BYO standing key *once* to `POST
   /v1/realtime/client_secrets`, then connect realtime with the resulting `ek_…`. This bounds
   token lifetime and keeps the standing key off the wire to the realtime endpoint. Works for
   both WebRTC and WebSocket.
2. **Direct connect with the BYO key:** acceptable *only* because it's the user's own key on
   their own device (simplest; matches AIProxySwift's WS default). Document the tradeoff.
3. **Add a backend later:** move minting server-side + add `OpenAI-Safety-Identifier`. The
   client code is identical (it always just receives an `ek_…`).

**Hard rule for the repo:** zero keys in source; placeholders (`<<PASTE_YOUR_OWN>>`) only;
Keychain at runtime. `[conf: high]`

---

## 4. Session configuration (GA shape)

Configure via the `session.update` client event (server replies `session.updated`). Most fields
are updatable mid-session **except `voice` after first audio**. **Max session = 60 minutes.**
Source: <https://platform.openai.com/docs/guides/realtime-conversations>. `[conf: high]`

```jsonc
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "model": "gpt-realtime-2",
    "instructions": "Speak clearly and briefly. Confirm before taking actions.",
    "output_modalities": ["audio"],            // was `modalities` in beta
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },  // pcm16 @24kHz mono LE
        "noise_reduction": { "type": "near_field" },        // optional: near_field | far_field
        "transcription": { "model": "gpt-4o-mini-transcribe", "language": "en" }, // optional captions
        "turn_detection": { "type": "semantic_vad", "eagerness": "medium" }
      },
      "output": {
        "format": { "type": "audio/pcm" },       // audio/pcm | audio/pcmu | audio/pcma
        "voice": "marin",
        "speed": 1.0                              // 0.25–1.5, between turns only
      }
    },
    "tools": [ /* see §5 */ ],
    "tool_choice": "auto",
    "max_output_tokens": "inf",                  // number | "inf"
    "reasoning": { "effort": "low" },            // gpt-realtime-2 only: minimal|low|medium|high|xhigh
    "parallel_tool_calls": true,                 // reasoning models only
    "prompt": { "id": "pmpt_123", "version": "89", "variables": { "city": "Paris" } } // optional reusable prompt
  }
}
```

Field notes (all from the realtime-conversations guide, the VAD guide, and the realtime
client-events / client-secrets API references; `[conf: high]` unless noted):

- **`output_modalities`**: `["audio"]` (audio + transcript) or `["text"]`.
- **Audio formats**: input/output each take `{ "type": "audio/pcm", "rate": 24000 }`
  (PCM is **24 kHz only**, mono, 16-bit little-endian) **or** `audio/pcmu` (G.711 μ-law) **or**
  `audio/pcma` (G.711 A-law). The old flat string `input_audio_format: "pcm16"` is **gone** in GA.
- **`turn_detection`** (under `audio.input`):
  - `server_vad`: `{ threshold (0–1), prefix_padding_ms, silence_duration_ms, create_response,
    interrupt_response }`. **Default** mode when VAD supported.
  - `semantic_vad`: `{ eagerness: "low"|"medium"|"high"|"auto", create_response,
    interrupt_response }`. Classifier decides end-of-utterance from *words*; `auto`≈`medium`;
    `low` = let the user ramble, `high` = chunk ASAP. Less likely to interrupt.
  - `null`: disables VAD (push-to-talk; you send `commit`/`response.create`/`clear` manually).
  - `create_response`/`interrupt_response: false` = keep VAD but you fire `response.create`
    yourself (useful for the **one-`response.create`-per-turn** discipline).
- **`transcription`** (under `audio.input`): `{ model, language, prompt, delay }`. **Off by
  default.** Models: `whisper-1`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-12-15`,
  `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize`, `gpt-realtime-whisper`. It runs
  *asynchronously* via `/audio/transcriptions` and is **guidance**, not exactly what the model
  heard. `delay` is `gpt-realtime-whisper`-only.
- **`reasoning.effort`**: `gpt-realtime-2` only; `minimal|low|medium|high|xhigh`, **default
  `low`**. (Use `minimal`/`low` for snappy voice.)
- **`temperature`**: limited to **[0.6, 1.2]**, 0.8 recommended. *(Present in the beta
  params/SDK; not surfaced cleanly on the GA session page — verify exact placement; §9.)* `[conf: med]`
- **`prompt`**: reusable server-stored prompts `{ id, version, variables }` (direct session
  fields override overlapping prompt fields).

---

## 5. Tools / function calling in realtime

Two tool families. Pick per job:

| Tool type | Who executes it | Use for |
|---|---|---|
| `function` | **Your client/server** (returns `function_call_output`) | your own business logic, private APIs, approvals |
| `mcp` (`server_url`) | **The Realtime API** calls the remote MCP server | tools already behind an MCP server |
| `mcp` (`connector_id`) | The Realtime API calls an OpenAI-managed connector | built-ins (`connector_googlecalendar`, `connector_gmail`, `connector_dropbox`, …) |

Source: *Realtime with tools / MCP* (<https://developers.openai.com/api/docs/guides/realtime-mcp>),
*Introducing gpt-realtime* (MCP support), realtime client-events reference. `[conf: high]`

### 5.1 Client-fulfilled `function` loop (the core for a minimal app)

1. **Declare** in `session.tools` (or `response.tools`):
   ```jsonc
   { "type": "function", "name": "generate_horoscope",
     "description": "Give today's horoscope for an astrological sign.",
     "parameters": { "type": "object",
       "properties": { "sign": { "type": "string", "enum": ["Aries", "…"] } },
       "required": ["sign"] } }
   ```
   plus `"tool_choice": "auto"`.
2. **Model decides to call** → emits a `function_call` item. Stream args via
   **`response.function_call_arguments.delta`**, completion via
   **`response.function_call_arguments.done`**; the full data is also on `response.done`:
   `response.output[0]` has `type:"function_call"`, `name`, **`call_id`**, and `arguments`
   (a JSON **string**).
3. **You execute** your code.
4. **Return the result** with `conversation.item.create`:
   ```jsonc
   { "type": "conversation.item.create",
     "item": { "type": "function_call_output", "call_id": "call_…", "output": "{\"horoscope\":\"…\"}" } }
   ```
5. **Ask for the spoken answer** with a single `response.create`.

> **Invariant for the minimal app:** exactly **one `response.create` per tool turn**. With
> server/semantic VAD, set `turn_detection.create_response:false` if you want to own that fire,
> and guard against firing a second `response.create` while one is active (and against the
> VAD auto-response double-fire). `[conf: high]`

### 5.2 MCP tools (optional, API-executed)

```jsonc
{ "type": "mcp", "server_label": "stripe", "server_url": "https://mcp.stripe.com",
  "authorization": "{access_token}", "require_approval": "never",
  "allowed_tools": ["…"], "server_description": "…", "defer_loading": false }
```
The API runs the tool; your client only configures access, listens for MCP lifecycle events
(`response.mcp_list_tools`, MCP tool-call, approval-request), and optionally approves. Built-in
connectors swap `server_url` for `connector_id` and take the user's OAuth token in
`authorization`. `[conf: high]`

### 5.3 Web search in realtime — **no native hosted tool**

There is **no built-in `web_search` hosted tool for the Realtime API.** A developer-community
thread (with confirmation attributed to OpenAI's Justin Umberti) states the realtime built-in
web search "doesn't work yet"; sending `{ "type": "web_search" }` hangs.
Source: <https://community.openai.com/t/does-the-built-in-web-search-tool-work-with-realtime-speech-api/1361699>. `[conf: med-high]`

**Recommended pattern:** declare a **client `function`** (e.g. `web_search(query)`); in its
handler, call the **Responses API** (`gpt-5`/`gpt-4o` with the `web_search` tool), then return
the summary as `function_call_output`. The realtime model then speaks it. This matches the
"web-search moment is a client-fulfilled deferred path" design.

> **Conflict flagged:** AIProxySwift's README exposes a GA `.webSearch` realtime tool
> (`tools: [.webSearch(.init(searchContextSize: .medium))]`). This **contradicts** OpenAI's
> "no native realtime web_search." Possibilities: it silently no-ops, or it's aspirational, or
> OpenAI shipped it after the community post. **Do not rely on a native realtime web_search;
> use the client-function pattern and verify independently.** `[conf: low on the SDK claim]` (§9)

---

## 6. What changed vs the older (preview/beta + AIProxySwift 0.153.0) baseline

> **Caveat on the prompt's framing:** `gpt-realtime-2` shipped **May 2026**, while "AIProxySwift
> 0.153.0 (mid/late-2025)" predates it. So the real baseline an old app ran was the **beta
> interface + `gpt-4o-realtime-preview*` (or the early `gpt-realtime` GA) with the *flat* session
> shape.** The deltas below are the API-surface changes that matter; SDK-version specifics are
> worker 07's lane. `[conf: high]` on the API deltas.

**Hard deprecations (removed 2026-05-07):** the **beta interface** (`OpenAI-Beta: realtime=v1`)
and all `gpt-4o-realtime-preview*` + `gpt-4o-mini-realtime-preview` models → replace with
`gpt-realtime-1.5` / `gpt-realtime-mini`. An app pinned to the beta protocol or a preview model
id is now a **hard outage**.
Source: <https://developers.openai.com/api/docs/deprecations>. `[conf: high]`

**Renames / reshapes (beta → GA):**

| Beta (old) | GA (current) |
|---|---|
| `session.modalities` | **`session.output_modalities`** |
| `session.voice` | **`session.audio.output.voice`** |
| `session.input_audio_format: "pcm16"` | **`session.audio.input.format: { type:"audio/pcm", rate:24000 }`** |
| `session.output_audio_format` | **`session.audio.output.format`** |
| `session.turn_detection` | **`session.audio.input.turn_detection`** |
| `session.input_audio_transcription` | **`session.audio.input.transcription`** |
| `response.text.delta` | **`response.output_text.delta`** |
| `response.audio.delta` | **`response.output_audio.delta`** (transcript: `response.output_audio_transcript.delta`) |
| `conversation.item.created` | **`conversation.item.added`** + **`conversation.item.done`** |
| ephemeral mint `POST /v1/realtime/sessions` | **`POST /v1/realtime/client_secrets`** (returns `ek_…`) |
| legacy content types | **`output_text` / `output_audio`** |

Sources: realtime-conversations server-event lists; PocketLantern beta→GA brief
(<https://pocketlantern.dev/briefs/openai-realtime-api-beta-to-ga-migration-before-may-7-2026-shutdown>);
OpenAI developer blog *Developer notes on the Realtime API*
(<https://developers.openai.com/blog/realtime-api>). `[conf: med-high]` (the rename *list* is
corroborated by 2 sources; treat exact `response.audio.delta`→`response.output_audio.delta` as
med — see §9.)

**New since the baseline (GA + gpt-realtime-2):**

- `reasoning.effort` (`minimal…xhigh`) and `parallel_tool_calls` (reasoning models). `[conf: high]`
- **128K** context (`gpt-realtime-2`), longer agentic sessions; "preambles", tool-call
  transparency, stronger recovery. `[conf: high]`
- **MCP tools + built-in connectors**, **image input**, **SIP** calling, **reusable prompts**. `[conf: high]`
- `audio/pcmu` + `audio/pcma` formats; `gpt-realtime-whisper` streaming STT + transcription
  `delay`; `gpt-4o-transcribe-diarize`. `[conf: high]`
- `marin`/`cedar` voices; `audio.output.speed`. `[conf: high]`

**AIProxySwift baseline specifics (for worker 07 to confirm):** uses **WebSocket**
(`URLSessionWebSocketTask`), not WebRTC. Its README still shows the **flat beta-style**
`OpenAIRealtimeSessionConfiguration` (`inputAudioFormat: .pcm16`, `inputAudioTranscription`,
`modalities`, `outputAudioFormat`, `turnDetection: .semanticVAD(eagerness:)`, `voice: "shimmer"`)
**and** carries GA migration notes + an open GA issue (#268, 2026-03-18). It accepts
`model: "gpt-realtime-2"`. Implication: an app on an old AIProxySwift that still sends the **beta
header** would be broken post-2026-05-07 and must be on a GA-capable SDK build.
Source: <https://github.com/lzell/AIProxySwift>, issue #268. `[conf: med]`

---

## 7. Recommended minimal setup for a BYO-key iOS app

- **Model:** `gpt-realtime-2` with `reasoning: { effort: "low" }` (or `"minimal"` for lowest
  latency). Offer `gpt-realtime-mini` as a cheap toggle.
- **Voice:** `marin` (or `cedar`). Lock-after-first-audio is fine for a single-voice app.
- **Transport:**
  - **Minimal core → WebSocket** via `URLSessionWebSocketTask` (zero extra deps, matches
    AIProxySwift heritage). You own mic capture (`AVAudioEngine`, 24 kHz PCM16), base64
    `input_audio_buffer.append`, playback, and `conversation.item.truncate` on barge-in.
  - **Production upgrade → WebRTC** (OpenAI-recommended; auto media + truncation) once you can
    take the Swift WebRTC dependency. Same event JSON over the `oai-events` data channel.
- **Auth:** BYO standing key in **Keychain** → **mint `ek_…` on-device** via
  `/v1/realtime/client_secrets` (TTL ~600s) → connect realtime with `ek_…`. Re-mint per session.
  Document the "add a backend to move minting server-side" upgrade. **Zero keys in source.**
- **VAD:** `semantic_vad`, `eagerness: "medium"` (matches the "always-open mic + barge-in"
  feel). Consider `create_response:false` to own the single `response.create` per turn.
- **Audio:** input `audio/pcm` @ 24 kHz mono; output `audio/pcm`.
- **Tools:** client `function` tools only for the MVP; one `response.create` per turn; total
  fallback on unknown/garbled tool calls. "Web search moment" = a client function that calls the
  Responses API (`web_search`) and returns `function_call_output`.
- **Transcription (optional):** `audio.input.transcription.model = "gpt-4o-mini-transcribe"` for
  on-screen captions (treat as guidance).

See `snippets/api-reference/` for copy-pasteable curl/JSON/Swift.

---

## 8. Sources (live, this session)

OpenAI official:
- Introducing gpt-realtime (GA, Aug 2025): <https://openai.com/index/introducing-gpt-realtime/>
- Advancing voice intelligence / gpt-realtime-2 (May 7 2026): <https://openai.com/index/advancing-voice-intelligence-with-new-models-in-the-api/>
- Model: gpt-realtime: <https://platform.openai.com/docs/models/gpt-realtime>
- Model: gpt-realtime-2: <https://developers.openai.com/api/docs/models/gpt-realtime-2>
- Realtime + WebRTC: <https://platform.openai.com/docs/guides/realtime-webrtc>
- Realtime conversations: <https://platform.openai.com/docs/guides/realtime-conversations>
- Voice activity detection: <https://platform.openai.com/docs/guides/realtime-vad>
- Realtime with tools / MCP: <https://developers.openai.com/api/docs/guides/realtime-mcp>
- Realtime client events reference: <https://developers.openai.com/api/reference/resources/realtime/client-events/>
- Create client secret reference: <https://developers.openai.com/api/reference/python/resources/realtime/subresources/client_secrets/methods/create/>
- Client Secrets (API reference, session schema): <https://platform.openai.com/docs/api-reference/realtime-beta-sessions>
- Deprecations: <https://developers.openai.com/api/docs/deprecations>
- Developer notes on the Realtime API: <https://developers.openai.com/blog/realtime-api>

Corroborating / third-party (used only to cross-check or flag conflicts):
- openai-python `client_secrets.py` (`ek_1234`): <https://github.com/openai/openai-python/blob/main/src/openai/resources/realtime/client_secrets.py>
- openai-agents-python issue #1746 (voice enum): <https://github.com/openai/openai-agents-python/issues/1746>
- Realtime web_search "doesn't work yet": <https://community.openai.com/t/does-the-built-in-web-search-tool-work-with-realtime-speech-api/1361699>
- PocketLantern beta→GA migration brief: <https://pocketlantern.dev/briefs/openai-realtime-api-beta-to-ga-migration-before-may-7-2026-shutdown>
- AIProxySwift (baseline SDK): <https://github.com/lzell/AIProxySwift> + issue #268
- Vapi realtime (voice-list conflict): <https://docs.vapi.ai/openai-realtime>

---

## 9. Open questions / unverified

1. **Exact `gpt-realtime-2` dated snapshot string.** The model page renders the alias but not a
   clean `gpt-realtime-2-YYYY-MM-DD`. **Verify in the dashboard / models list before pinning.** `[conf: med]`
2. **`response.audio.delta` → `response.output_audio.delta` rename.** The conversations guide's
   server-event tables use `response.output_audio.delta`, but one inline snippet still shows
   `response.audio.delta`. Treat `output_audio.delta` as canonical; **confirm against the live
   server-events reference** when wiring handlers. `[conf: med]`
3. **`temperature` in GA session.** Present in beta params/SDK ([0.6,1.2], rec 0.8); not cleanly
   surfaced on the GA session page. **Confirm field + range before relying on it.** `[conf: med]`
4. **AIProxySwift `.webSearch` realtime tool vs OpenAI "no native realtime web_search."** Direct
   conflict. Don't rely on a hosted realtime web_search; use the client-function pattern. Worker
   07 should confirm what the SDK's `.webSearch` actually emits/does. `[conf: low on SDK claim]`
5. **Native iOS WebRTC dependency choice** (Google `WebRTC.xcframework` vs LiveKit vs staying on
   WebSocket) is an architecture decision, not an API fact — deferred to the builder/SPEC.
6. **`noise_reduction.type` enum** (`near_field`/`far_field`) inferred from beta params; confirm
   the exact GA allowed values. `[conf: med]`
7. **`gpt-realtime-mini` precise specs** (context/pricing) not fully pulled this session;
   confirm if it becomes the default cheap tier. `[conf: med]`
