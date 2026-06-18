# 01 — Realtime core: session lifecycle + tool engine + actor→UI bridge

> Worker slice: the **heart** of Pebbles — the realtime session, the tool-calling engine, and
> the `@AIProxyActor`→`@MainActor` event bridge. Everything cited to `file:line`. Confidence
> tags: **high** = read directly at the cited line; **med** = inferred from usage; **low** = guess.
>
> **Redaction:** real AIProxy partial keys + service URLs live at `RealtimeManager.swift:182-183`
> (OpenAI) and `:862-863` (Exa). They are **redacted to `<<PASTE_YOUR_OWN>>` in every snippet**;
> this doc only *names* the line numbers, it does not reproduce the values.

## Files read (coverage)
| File | Lines | Read |
|---|---|---|
| `OpenAIRealtimeSample/RealtimeManager.swift` | 1563 | 1563/1563 ✅ |
| `OpenAIRealtimeSample/Conversation/ConversationModel.swift` | 494 | 494/494 ✅ |
| `OpenAIRealtimeSample/Pebbles/PebblesState.swift` (PebblesEvent/State/Tone) | 106 | 106/106 ✅ |
| `OpenAIRealtimeSample/Conversation/Personality.swift` | 77 | 77/77 ✅ |
| `OpenAIRealtimeSample/Conversation/BrainProvider.swift` | 52 | 52/52 ✅ |
| `OpenAIRealtimeSample/Support/TurnTrace.swift` | 95 | 95/95 ✅ |
| `OpenAIRealtimeSample/Engine/AudioLevelMeter.swift` | 84 | 84/84 ✅ |
| `OpenAIRealtimeSample/Conversation/ToneInference.swift` | 108 | 108/108 ✅ |
| (corroborating) `Stage/PostItModel.swift` `PostItContent`/`Kind` | — | 1-126 |
| (corroborating) `Factory/ComponentPayloads.swift` `ComponentRequest` | — | 200-260 |

Snippets written: `snippets/realtime/01-lifecycle.swift`, `02-tool-dispatch.swift`,
`03-event-bridge.swift`, `04-tool-schemas.swift`, `05-aiproxy-sdk-surface.md`,
`06-audio-level-meter.swift`.

---

## 1. The minimal realtime lifecycle

**Shape:** `connect → session config → mic streaming → receiver loop → state emission → stop`.
All of it lives on the SDK's global actor `@AIProxyActor` so the receiver loop, the mic loop, and
every send share one executor with no locks (`RealtimeManager` is `@AIProxyActor final class`,
`RealtimeManager.swift:22`, **high**). Full redacted copy: `snippets/realtime/01-lifecycle.swift`.

**Exact sequence** (`startConversation`, `:151-409`, **high**):

1. **Generation bump (before any `await`)** — `sessionGeneration += 1; let myGeneration = …`
   (`:162-163`). This snapshot is the "stop always wins" guard; every gate below compares to it.
2. `emitState(.connecting)` (`:180`).
3. **Credentials** (`:182-187`, **REDACT**) → `AIProxy.openAIService(partialKey:serviceURL:)`
   (`:189-192`). BYOK-direct alt is `AIProxy.openAIDirectService(unprotectedAPIKey:)` (`:194-195`).
4. **Flags**: `aiSpeaksFirst = true` (`:198`), `allowBargeIn = true` (`:199-202`).
5. **Audio**: `AudioController(modes:[.playback,.record], useManualEchoCancellation: allowBargeIn)`
   then `micStream()` (`:204-208`). One VoiceProcessingIO (VPIO) unit — overlapping units crash
   (see Risks). `AudioController` is **SDK-provided, not in this repo** (grep `class AudioController`
   → 0 hits, **high**).
6. **Context assembly** (full app only): memory + reminders + recent-conversation blocks spliced
   into the prompt (`:214-241`). Cut for MVP.
7. **`OpenAIRealtimeSessionConfiguration(...)`** (`:229-264`, **high**): `inputAudioFormat:.pcm16`,
   `inputAudioTranscription:.init(model:"gpt-4o-mini-transcribe")`, `instructions:`,
   `maxResponseOutputTokens:.int(4096)`, `outputModalities:[.audio]`, `outputAudioFormat:.pcm16`,
   `tools: Self.agentTools`, `toolChoice:.auto`, `turnDetection:.semanticVAD(.init(createResponse:
   true, eagerness:.auto, interruptResponse: allowBargeIn))`, `voice:.builtin(personality.voiceName)`.
8. **Open the session**: `openAIService.realtimeSession(model:"gpt-realtime-2", configuration:,
   logLevel:.debug)` (`:266-270`, **high**). ⚠️ model string must be re-confirmed via live docs.
9. **Cancellation/generation gate** (`:280-285`): if superseded mid-connect, `audioController.stop()`
   + `realtimeSession.disconnect()` + dormant + `return` (avoids a leaked VPIO render thread).
10. **Mic → OpenAI Task** (`:288-300`): `for await buffer in micStream { meter; if ready, send
    OpenAIRealtimeInputAudioBufferAppend(audio: base64) }`. `isOpenAIReadyForAudio` gates the send.
11. **Receiver Task** (`:303-397`): `for await message in realtimeSession.receiver { generation
    guard; switch message { … } }`.
12. **Final gate + publish** (`:399-408`): re-check generation, then assign `self.realtimeSession`
    / `self.audioController`.

**Receiver `switch` → state machine** (`:308-394`, **high**). The 1:1 map (event → `PebblesState`):

| Receiver case | Action | `PebblesState` |
|---|---|---|
| `.sessionUpdated` | greeting if `aiSpeaksFirst` (**response.create #1**), else open mic | `.idle` |
| `.responseCreated` | `responseInFlight=true`; ready-for-audio = barge-in | `.thinking` |
| `.responseAudioDelta` | meter TTS + `playPCM16Audio` | `.speaking` |
| `.responseTranscriptDelta/Done` | emit pebbles transcript delta/final | — |
| `.inputAudioTranscriptionDelta/Completed` | emit user transcript delta/final | — |
| `.inputAudioBufferSpeechStarted` | barge-in: `interruptPlayback()` | `.listening` |
| `.responseFunctionCallArgumentsDone` | `searching` for web_search; `handleFunctionCall` | (`.searching`) |
| `.responseDone` | `responseInFlight=false`; reset TTS meter | `.idle` |
| `.error` | transient→reconnect, else dormant | `.dormant` |

**Stop** (`stopConversation`, `:411-440`, **high**): stop audio, disconnect, nil the session,
reset meters, **bump generation** (`:432`, invalidates any in-flight connect/reconnect), reset
`responseInFlight`, `emitState(.dormant)`.

**Mute** (`setMuted`, `:134-140`): just withholds outgoing mic packets (`if self.muted { continue }`
at `:291`); the session stays live. **high**.

---

## 2. The one-`response.create`-per-turn invariant (the key teaching pattern)

> **Rule:** exactly **ONE** `OpenAIRealtimeResponseCreate()` per turn. Verified: exactly **4**
> literal sites in `RealtimeManager.swift` (`:333, :548, :818, :840`) — **high** (grepped).
>
> **Why it holds:** a bare `conversation.item.create` (a `functionCallOutput`, a `role:"user"`
> item, or a `role:"system"` note) **does not trigger a model response** — only `response.create`
> does (stated `:537-538, :554-558, :566`, **high**). So tool outputs, context-syncs, and choice
> items can be appended freely; the single `response.create` is what actually makes the model speak.

**The 4 sites, by symbol/branch:**

1. **Greeting** — `.sessionUpdated` case, `if aiSpeaksFirst` (`:331-333`). The AI opens the
   conversation. Sets `responseInFlight=true` **before** the send (`:332`).
2. **`sendUserChoice(_:)`** (`:533-549`). A user taps an option on a `choice` card. This is a
   **new user turn**: a `role:"user"` item (`:539-541`) **plus at most one** `response.create`
   (`:548`) — *not* a 2nd response on the `render_component` (show) turn. Tap-driven (no audio) so
   server-VAD can't double-fire it; guarded by `responseInFlight` so a tap mid-turn only appends
   the user item and rides the next free turn (`:542-545`).
3. **Inline tool tail** — end of `handleFunctionCall` (`:801-818`). FAST/local tools fall through
   to: send `functionCallOutput` (`:801-805`) → optional `role:"system"` context-sync note
   (`:809-815`) → the ONE `response.create` (`:817-818`).
4. **Shared deferred tail** — `completeDeferredToolTurn(callID:output:on:)` (`:829-841`). SLOW
   tools funnel here: `functionCallOutput` + the ONE `response.create` (`:840`). Extracting this
   into ONE helper is *what keeps the count at 4* — every slow tool reuses it (`:823-828`, **high**).

**Inline vs. deferred branch rule** (`:587-603`, **high**):

- **DEFERRED (slow / network tools):** `web_search` (`:592-603`) and `consult_openclaw` (`:609-654`).
  They must **not** be `await`ed inside `handleFunctionCall` — that blocks the receiver loop and
  **freezes audio**. Each kicks off a detached `Task { … await network … await
  completeDeferredToolTurn(…) }` and `return`s. They add **no** `response.create` of their own.
- **INLINE (fast / local tools):** memory remember/forget, `surface_note`, `render_component`,
  `dismiss/collect/park/clear_notes` (`:667-799`). They `await` cheaply, set `output` (+ optional
  `contextSyncNote`), and fall through to the **single shared inline send** (`:801-818`).

**Double-fire guard (FIX C):** `responseInFlight` is set to `true` **before** every send, not just
on the server's `.responseCreated` (`:332, :546, :817, :839`, **high**). Combined with server-VAD's
`createResponse:true` (`:255`) auto-response, this closes the pre-round-trip window where a manual
`response.create` could collide with the server's. The conservative transient-error classifier even
lists "already has an active response" as recoverable (`:449-451`).

> **Teaching one-liner:** *Build every new tool on the inline fall-through or the shared deferred
> tail. A choice pick is a new user turn. A context nudge is `role:"system"` + zero response.create.
> Never hand-write a 5th `response.create`.*

---

## 3. The tool-calling pattern (declare → dispatch → fulfill → respond)

Clean copy: `snippets/realtime/02-tool-dispatch.swift` + `04-tool-schemas.swift`.

**Declare** (`agentTools`, `:1137-1432`, **high**). Each tool is
`.function(.init(name:description:parameters:))` where `parameters` is a JSON-Schema dictionary
`[String: AIProxyJSONValue]` (`type:"object"`, `properties`, `required`, `additionalProperties:false`).
Patterns to copy:
- no params → empty-object schema (`clear_notes`, `:1300-1304`);
- one required string (`web_search`, `:1176-1186`);
- enum + required/optional (`surface_note`, `:1211-1239`);
- enum derived from a Swift `CaseIterable` so schema can't drift from the registry
  (`render_component`, `:1311-1336` uses `ComponentID.allCases`).

**Dispatch** (`:369-375` → `handleFunctionCall`, `:583`, **high**). The receiver hands the
`OpenAIRealtimeResponseFunctionCallArgumentsDoneEvent` (fields `.name`, `.arguments` (JSON string),
`.callID`) to `handleFunctionCall`. Optional per-tool UI state is set first (e.g. `.searching` for
`web_search`, `:371`).

**Decode** (`decodeArguments`, `:1122-1125`, **high**): `try? JSONDecoder().decode(...)` over the
arguments string. Args structs have **optional** fields so a malformed payload → `nil`/partial →
graceful output, never a crash (`:991-1038`).

**Fulfill + respond (inline)**:
1. do the work → build `output` JSON via `jsonString(_:)` (`:1127-1133`);
2. send `functionCallOutput(callID:output:)` (`:801-805`);
3. optionally send a `role:"system"` `contextSyncNote` to keep the model's working set honest
   (`:809-815`; builders at `:1051-1094`);
4. the single `response.create` (`:817-818`).

**Recipe — how to add a tool** (codified in `02-tool-dispatch.swift`):
1. Args struct (Decodable, optional fields).
2. JSON-Schema dict `[String: AIProxyJSONValue]`.
3. Append `.function(.init(...))` to `agentTools`.
4. Handle in `handleFunctionCall`: FAST → add a `switch case`, set `output`(+`contextSyncNote`),
   fall through to the shared inline send; SLOW → handle at the TOP with `Task { … await
   completeDeferredToolTurn(…) }` + `return`.
5. Add a `contextSyncNote` if the tool changes state the connect-time prompt described.
6. Update `instructions(...)` so the model knows when to call it.

**Worked example — `web_search` (the slow path)** (`:592-603, :859-917`, **high**): dispatch decodes
`{query}`, spawns a `Task`, calls `performWebSearch` (Exa `/search` via a **second, separate** proxy
service — keys at `:862-863`, **REDACT**), maps results to a compact `{query, results:[{title,url,
snippet}]}` envelope, then `completeDeferredToolTurn`. It never throws (every failure → a JSON error
envelope the model reads aloud).

---

## 4. The event bridge (`@AIProxyActor` → `@MainActor`)

Clean copy: `snippets/realtime/03-event-bridge.swift`.

**Producer side** (`RealtimeManager`, **high**): `nonisolated let events: AsyncStream<PebblesEvent>`
+ its `Continuation` (`:32-33`), created in `init` via `AsyncStream.makeStream(of:)` (`:130`).
`nonisolated` is the trick — the `@MainActor` model can read `events`/`micMeter`/`pebblesMeter`
without hopping the actor (`:32-36`). `emit(_:)` yields (`:142`); `emitState(_:)` dedups state so
the ~50/s audio deltas don't spam state changes (`:145-149`).

**Consumer side** (`ConversationModel`, `@MainActor @Observable`, `:13-15`, **high**): the **sole**
drainer is one long-lived task — `eventTask = Task { for await event in mgr.events { self?.apply(event) } }`
(`:188-192`). `apply(_:)` (`:319-351`) maps each case to an `@Observable` mutation the SwiftUI stage
reads.

**`PebblesEvent` cases + what each drives** (`PebblesState.swift:86-105` + `apply`
`ConversationModel.swift:319-351`, **high**):

| Case | Payload | Drives (in `apply`) |
|---|---|---|
| `.state` | `PebblesState` | `liveState` (animated); clears `userText` on `.listening`, `pebblesText` on `.thinking` (`:321-324`) |
| `.tone` | `PebblesTone` | `tone` (`:331-332`) — **but the manager never emits this** (see note) |
| `.userTranscriptDelta` | `String` | `userText +=` (`:333-334`) |
| `.userTranscriptFinal` | `String` | set `userText`; `history.record`; `inferTone` (`:335-341`) |
| `.pebblesTranscriptDelta` | `String` | `pebblesText +=` (`:342-343`) |
| `.pebblesTranscriptFinal` | `String` | set `pebblesText`; `history.record` (`:344-346`) |
| `.note` | `PostItContent` | `noteRequest` → a floating card (`:325-326`) |
| `.component` | `ComponentRequest?` | `renderComponentRequest` (factory); `nil` ⇒ fallback (`:327-328`) |
| `.memoryChanged` | — | bump `memoryRevision` to refresh memory UI (`:329-330`) |
| `.error` | `String` | go `.dormant` (`:347-350`) |

**`PebblesState`** (`:13-20`): `dormant, connecting, idle, listening, thinking, searching, speaking`
— plus orb affordances (`energy`/`breathPeriod`/`baseScale`/`statusLabel`, `:22-75`).
**`PebblesTone`** (`:80-82`): `neutral, warm, concerned, playful`.

> **Landmine (high):** the **manager only emits** `.state, .error, .note, .component,
> .memoryChanged`, and the 4 transcript cases. It **never emits `.tone`** — tone is computed
> *locally* on the MainActor from user finals via `ToneInference.tone(forUserText:)`
> (`ConversationModel.swift:430-436`). So `.tone` is effectively a UI-internal channel. For an MVP
> you can drop the `.tone` case + `ToneInference` and lose nothing in the realtime loop.

**Levels for the visualizer** (`currentLevel()`, `ConversationModel.swift:241-247`): returns
`micMeter.level()` while `.listening`, `pebblesMeter.level()` while `.speaking`, else 0 — the orb
reads this per frame. The meters are `AudioLevelMeter` (`snippets/realtime/06-audio-level-meter.swift`),
fed at `:293` (mic) and `:339` (TTS).

---

## 5. MVP recommendation (keep vs. cut)

### Tools — KEEP 2–3
- ✅ **`get_time`** *(new, trivial)* — the dead-simple **inline** example (no deps). Demonstrates
  the fast branch + the single inline `response.create` in ~5 lines.
- ✅ **`web_search`** — the canonical **deferred/slow** example. Teaches the detached-Task → shared
  tail rule and "speak first, then search". Keep, but make the proxy **BYOK/optional** (it already
  no-ops gracefully when unconfigured, `:871-874`). *(Or stub it to return canned JSON so the repo
  runs with zero extra keys.)*
- ✅ (**pair with factory worker**) **`surface_note`** *or* **`render_component`** — the simplest UI
  tool, to show `emit(.note)`/`emit(.component)` + the `contextSyncNote` working-set discipline.
  `surface_note` is lighter; `render_component` is the richer "model passes data, never behavior"
  pattern (defer to worker 02's recommendation).

### Tools — CUT for MVP
- ❌ **memory** (`remember/forget_about_user`) — needs `MemoryStore` + JSON persistence (`:668-694`).
- ❌ **`consult_openclaw`** + `BrainProvider`/`OpenClawBrain` — needs a whole tailnet backend
  (`:605-654`, `BrainProvider.swift`). Big surface, zero value without the backend.
- ❌ **`dismiss/collect/park/clear_notes`** — need `SurfaceStore` lifecycle + the `@MainActor
  @Sendable` provider closures threaded through `startConversation` (`:52-73, 732-799`).
- ❌ **`TurnTrace`** latency tracing (`Support/TurnTrace.swift`) — nice ops telemetry, not core.
- ❌ The **`pendingNote`** search-note timing flourish (hold the card until TTS starts, `:44, 571-575`)
  — simplify by surfacing immediately (like `surface_note` already does).

### Lifecycle hardening — MVP vs. stretch
- ✅ **MVP — turn-guard** (`responseInFlight`, FIX C set-before-send, `:79, 332, 546, 817, 839`):
  ~5 lines, prevents the double-fire that the server rejects. Cheap, essential.
- ✅ **MVP — barge-in** (`turnDetection.interruptResponse` + `.inputAudioBufferSpeechStarted` →
  `interruptPlayback()`, `:253-259, 359-368`): this is what makes it feel like a real agent.
- ✅ **MVP — generation guard ("stop always wins")** (`:162-163, 280-285, 307, 399-408, 432`):
  needed because connect has `await` suspension points; keep a simplified version (it also prevents
  the VPIO double-unit crash).
- 🟡 **Stretch — semantic VAD tuning** is free to keep (it's just config), but `eagerness:.auto`
  is a fine default (`:200-201, 256`).
- 🟡 **Stretch — auto-reconnect on transient error** (S3, `:442-521`): non-trivial (transient
  classifier, storm cap ≤3/60s, teardown-before-connect VPIO ordering). Document it; ship later.
  Note the *reason* it exists is a real SDK constraint (next section).
- 🟡 **Stretch — `ToneInference`** (`Conversation/ToneInference.swift`, dependency-free ~108 lines):
  a charming local read of the user; pure UI. Keep only if you also keep the orb tinting.

---

## 6. Source map (exact `file:line` to lift/adapt)

**`OpenAIRealtimeSample/RealtimeManager.swift`**
- Manager shell + event bridge fields: `22-36`; `init` + `emit`/`emitState`: `122-149`.
- **Lifecycle** `startConversation`: `151-409` (config `229-264`; open `266-270`; cancel gate
  `280-285`; mic loop `288-300`; receiver loop `303-397`; publish gate `399-408`).
- `stopConversation`: `411-440`. `setMuted`: `134-140`.
- **response.create sites**: greeting `333`; `sendUserChoice` `533-549`; inline tail `801-818`;
  shared deferred tail `completeDeferredToolTurn` `829-841`.
- **Tool engine** `handleFunctionCall`: `583-821` (deferred web_search `592-603`; deferred
  consult `609-654`; inline switch `667-799`). `sendContextUpdate`: `559-567`.
- `web_search` fulfillment `performWebSearch`: `859-917` (**REDACT `862-863`**); note distill
  `939-978`. Args structs: `991-1038`. Decode/JSON helpers: `1122-1133`.
- **Tool schemas** `agentTools`: `1137-1432`. **System prompt** `instructions`: `1440-1551`.
- ⚠️ **REDACT** OpenAI keys: `182-183`.

**`OpenAIRealtimeSample/Pebbles/PebblesState.swift`** — `PebblesState` `13-76`; `PebblesTone`
`80-82`; **`PebblesEvent`** `86-105`. (Lift whole file — no secrets.)

**`OpenAIRealtimeSample/Conversation/ConversationModel.swift`** — drainer `init`+`eventTask`
`159-192`; `currentLevel` `241-247`; `toggle/start/stop` `251-315`; **`apply(_:)`** `319-351`;
local tone `inferTone` `430-449`. (Cut memory/history/surface-provider plumbing for MVP.)

**`OpenAIRealtimeSample/Engine/AudioLevelMeter.swift`** — whole file `1-84` (lift as-is, no secrets).

**`OpenAIRealtimeSample/Conversation/Personality.swift`** — `Personality` struct `12-24`; Pebbles
instance `29-68`. (Trim to `id/name/voiceName/persona/core` for MVP.)

**Optional / stretch:** `Support/TurnTrace.swift` `1-95`; `Conversation/BrainProvider.swift` `1-52`;
`Conversation/ToneInference.swift` `1-108`.

**SDK surface** (match or replace with raw WebSocket): see `snippets/realtime/05-aiproxy-sdk-surface.md`.

---

## Risks / landmines
- **VPIO crash (high).** Overlapping VoiceProcessingIO units crash inside the SDK mic vendor. Mitigated
  by: drop the in-flight session on cancellation (`:276-285`), and **stop OLD audio before building
  new** in reconnect (`teardownAudioAndSession` `:458-471`, called at `:498` *before* the new
  `startConversation`). Any new repo doing reconnect/restart must preserve this ordering.
- **Double-fire (high).** Server-VAD `createResponse:true` (`:255`) + a manual `response.create` can
  collide. Guard = `responseInFlight` set **before** the send (FIX C). A duplicate is server-rejected
  as a transient error (`:449-451`).
- **Key leakage (high).** Real partial keys + service URLs at `:182-183` (OpenAI) and `:862-863`
  (Exa). All redacted to `<<PASTE_YOUR_OWN>>` in snippets; verified the staging folder has none.
- **SDK halts its own receive loop on ANY error (med).** A transient error leaves a *zombie*
  session that can no longer receive — recovery **requires a reconnect** (rebuild), not "just don't
  disconnect" (`:81-84, 310-312`). This is the whole reason auto-reconnect exists; informs the
  MVP-vs-stretch call.
- **"Bare item ≠ response" relied on (med).** Context-syncs and choice items only work because a
  `conversation.item.create` doesn't trigger a response (`:537-538, 554-558`). If a future API
  changes that, the count discipline breaks.
- **`AudioController` is not in the repo (high).** It's an SDK helper. A raw-WebSocket BYOK repo must
  reimplement mic capture + PCM16 playback + echo cancellation (AVAudioEngine + voice processing).
- **Model string drift (high).** `"gpt-realtime-2"` (`:267`) is hardcoded; confirm the latest GA
  model + voices via live docs before shipping (worker F).

## Confidence & verification
- **High** for everything quoted at a line (read the full files; line numbers re-grepped). Verified
  the **4** `response.create` sites by `rg` (`333, 548, 818, 840`). Verified `AudioController`,
  `ComponentRequest`, `PostItContent` definition locations by `rg`.
- **Med** for AIProxy SDK *type internals* (init params, enum cases) — inferred from call sites, not
  from the SDK source (not in this repo).
- Did **not** run a build or the sim (read-only slice; no source edited). Did **not** research the
  web (model-string confirmation is worker F's job).
