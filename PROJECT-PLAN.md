# PROJECT-PLAN — building the minimal repo (agent-ready)

> Companion to `SPEC.md`. This decomposes the build into **tiers** of **self-contained task cards** you
> can hand to implementation agents (one card ≈ one agent, or fan a whole tier out at once). Each card
> names its **inputs** (which `research/*` + `snippets/*` to read), **steps**, and **acceptance criteria**.
>
> **Golden rules for every implementer** (paste into each agent prompt):
> - **Never commit a secret** (SPEC N1). Use placeholders + Keychain. The 4 secrets to strip are in
>   `research/05`. Don't copy the source `.xcodeproj`/`.pbxproj`.
> - **Hold the realtime invariant** (SPEC N2): exactly one `response.create` per tool turn.
> - **Total fallback** (SPEC N3), **views never own audio** (N4), **one stream/one drainer** (N5),
>   **level off observation** (N6).
> - New files auto-include (`PBXFileSystemSynchronizedRootGroup`) — never hand-edit the pbxproj.
> - Build **Debug AND Release**; verify on an iOS sim per the loop in §4.

---

## 0. Resolve D1 first (5-min decision, blocks Phase 1's shape)

Pick the transport/SDK path (`SPEC §3 D1`):
- **(default) AIProxySwift-BYOK** → Phase 1 reuses `RealtimeManager` + the SDK's `AudioController`. Fast, low-risk.
- **(alt) raw `URLSessionWebSocketTask`** → Phase 1 also builds an `AudioController` (AVAudioEngine 24 kHz
  PCM16 + echo cancel + playback); use `snippets/api-reference/05-websocket-connect.swift` + `02-session-update.ga.json`.

Everything below is written for the default; the raw-WS alt only changes cards **T1.2** and **T1.3**.

---

## 1. Build tiers & dependency graph

```
Tier 0  Project skeleton + key plumbing        ──┐
Tier 1  Realtime voice (the heart)               │ (sequential spine)
Tier 2  Tool calling                             │
Tier 3  Character (SpriteKit)        ┐ parallel after Tier 2 (both need the Tier-1/2 core
Tier 4  Agent-driven cards (factory) ┘  + the Tier-3/4 share the composition host T3.0)
Tier 5  Stretch (ephemeral backend, raw-WS, re-add components/flourishes)
```

- **Tiers 0→1→2 are sequential** (each builds on the last; this is the MVP-minimum: a talking,
  tool-calling agent).
- **Tiers 3 and 4 parallelize** once the composition host exists — build **T3.0 (composition spine)** first,
  then the character (T3.x) and the cards (T4.x) are largely independent (disjoint files).
- **Tier 5** is post-MVP.

**Minimum shippable demo = end of Tier 2.** Showcase demo = end of Tier 4.

---

## 2. Task cards

> Effort: S ≈ <½ day · M ≈ ~1 day · L ≈ multi-day. "Parallel-safe" = disjoint file ownership.

### Tier 0 — Skeleton + keys *(no Ray keys ever)*

**T0.1 — Fresh Xcode project & build config** · S · (root task, others depend on it)
- Inputs: `research/05`, `snippets/config/*`.
- Steps: new iOS app (blank Team, neutral bundle id); set deployment target (SPEC §3), mic usage key,
  `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, `GENERATE_INFOPLIST_FILE=YES`, file-system-synchronized group;
  add `.gitignore` + `Config/Secrets.xcconfig.example`; add AIProxySwift `0.153.0` via SPM (skip if raw-WS).
- Accept: empty app builds Debug+Release on an iOS sim; no Team ID/bundle-id/keys in the repo; `git status` clean of secrets.

**T0.2 — Key plumbing (paste-key → Keychain)** · M · parallel-safe (owns `Keys/`)
- Inputs: `research/07`, `snippets/keys/{KeychainStore,RealtimeCredentialProvider}.swift`.
- Steps: Keychain store (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); a `RealtimeCredentialProvider`
  seam (paste-key now, ephemeral later); a minimal "enter your OpenAI key" settings screen.
- Accept: key persists across launches in Keychain (never UserDefaults); provider returns a usable credential; no key in logs.

### Tier 1 — Realtime voice (the heart) *(depends on T0.1, T0.2)*

**T1.1 — Event model + bridge** · S · parallel-safe (owns `Realtime/PebblesEvent`, `PebblesState`)
- Inputs: `research/01`, `snippets/realtime/03-event-bridge.swift`.
- Steps: `PebblesEvent` enum + `PebblesState`; the `nonisolated AsyncStream` + single `@MainActor` drainer shape.
- Accept: compiles; a fake emit flows through the drainer to an observable property (N5).

**T1.2 — RealtimeManager lifecycle** · L · (core; do before T1.3/T2.x)
- Inputs: `research/01`, `snippets/realtime/{01-lifecycle,05-aiproxy-sdk-surface}.swift`; `research/06 §session config`.
- Steps: `@AIProxyActor RealtimeManager`: connect → GA session config (model `gpt-realtime-2`, voice, semantic
  VAD, pcm16) → mic loop → receiver `switch` → state emit → generation-guarded `stop`. Greeting = `response.create` site #1.
- Accept: connects with a pasted key; greets on launch; `stop` tears down cleanly; **VPIO**: no overlapping
  audio units on stop/restart (research/01 landmine).

**T1.3 — ConversationModel + minimal screen** · M · (depends on T1.1, T1.2)
- Inputs: `research/01`, `research/04 §router/caption seams`.
- Steps: `@MainActor @Observable ConversationModel` (the drainer); a SwiftUI screen with connect/stop/**mute**
  + live captions (user + agent transcripts).
- Accept: you can hold a spoken conversation with barge-in; captions stream; mute stops mic without dropping the session.

### Tier 2 — Tool calling *(depends on Tier 1)*

**T2.1 — Tool dispatch engine + the invariant** · M · (core)
- Inputs: `research/01`, `snippets/realtime/{02-tool-dispatch,04-tool-schemas}.swift`.
- Steps: `handleFunctionCall` (lenient decode → fulfill → `function_call_output` → the single send);
  `completeDeferredToolTurn` (site #3) + inline tail (site #4); `sendUserChoice` (site #2) + `sendContextUpdate`
  (no `response.create`); the `responseInFlight` guard.
- Accept: **exactly 4** `OpenAIRealtimeResponseCreate` sites (grep audit, SPEC N2); a tool turn never double-fires.

**T2.2 — MVP tools: `get_time` + `web_search`** · M · parallel-safe after T2.1
- Inputs: `research/01 §tools`, `research/06 §tools` (no native realtime web_search!).
- Steps: `get_time` inline (zero network); `web_search` as a **deferred client function** — BYO/stubbed (do
  NOT use the SDK `.webSearch` case). Speak-first preamble on the slow tool.
- Accept: agent calls `get_time` and answers; `web_search` runs on the deferred tail (audio keeps flowing) and
  degrades gracefully when unconfigured.

### Tier 3 — Character *(depends on Tier 2 core; build T3.0 before T3.1 & all of Tier 4)*

**T3.0 — Composition spine (shared host for character + cards)** · L · (gate for T3.1 + Tier 4)
- Inputs: `research/04`, `snippets/composition/{01-CompositionSpine,02-StageViewController}.swift`.
- Steps: `@main` → `CompositionRoot` (DI) → `StageHost` → `StageViewController` sandwich
  (background ‹ SKView ‹ FloatingCanvas ‹ foreground) with the **reversed-priority hitTest**; move the Tier-1
  screen's captions/controls into `StageForeground`.
- Accept: the sandwich renders; taps reach the character layer behind the greedy SwiftUI host; audio still owned
  by the model (N4).

**T3.1 — SpriteKit character** · M · parallel-safe with Tier 4 (owns `Character/`)
- Inputs: `research/03`, `snippets/spritekit/{MinimalCharacterScene,CharacterState,CharacterView,AudioLevelMeter}.swift`.
- Steps: orb + 2 eyes; `StateLook.make(state)`; **per-frame** amplitude via `levelProvider` (N6); mic vs TTS
  `currentLevel()`; reduceMotion.
- Accept: character pulses with the agent's voice, draws-in while listening, blinks; **no** level read through
  observation/`@State` (N6); single persistent scene instance.

### Tier 4 — Agent-driven cards (factory) *(depends on T2.1 + T3.0; parallel with T3.1)*

**T4.1 — Factory infra + fallback + assert** · M · (gate for T4.2/T4.3)
- Inputs: `research/02`, `snippets/factory/{ComponentID,ComponentPayloads,ComponentFactory,FactoryContext,FallbackComponentVC,Registration}.swift`.
- Steps: id enum, opaque `JSONValue` payload, builder contract, **total fallback** (N3), `registerComponents()`
  + **`assertAllRegistered()`** (fixes the silent-registration footgun).
- Accept: unknown id / bad payload / nil call → fallback card, never a crash; launch assert catches an unregistered id.

**T4.2 — MVP components: note, choice, statCard** · M · parallel-safe (each component is independent)
- Inputs: `research/02`, `snippets/factory/{NoteComponent,ChoiceComponent,StatCardComponent}.swift`.
- Steps: 3 bodies; `choice` wires `onUserChoice` → `sendUserChoice` (a new user turn, site #2 — not a 2nd response).
- Accept: each renders from a typed payload; choice tap is local/instant then rides a new user turn.

**T4.3 — `render_component` tool + minimal surfaces** · M · (depends on T2.1, T3.0, T4.1)
- Inputs: `research/01 §render_component`, `research/04 §surface model`,
  `snippets/composition/{03-SurfaceStore,04-FloatingCanvas,05-CardViewController}.swift`.
- Steps: `render_component` tool (id enum from `allCases`); minimal `SurfaceStore` (floating + present/dismiss/
  bringToFront); `FloatingCanvas.sync()`; `CardViewController` (glass + drag + transform-free size cache).
- Accept: the agent says "show me X" → a card appears; cards drag; unknown id → fallback; card sizing stable under the held-scale transform.

### Tier 5 — Stretch (post-MVP)

- **T5.1** ephemeral-token mode (`snippets/keys/{EphemeralTokenClient, mint-token.*}` + `snippets/api-reference/01-mint-ephemeral-client-secret.sh`).
- **T5.2** raw-WS transport + own AudioController (`snippets/api-reference/05-websocket-connect.swift`).
- **T5.3** re-add components (list/charts/rings/image/progress) and character flourishes (cairn/physics/hop/glance) — line ranges in `research/02 §5` and `research/03 §5`.
- **T5.4** re-add memory store / context resurfacing / history if desired.

---

## 3. Suggested agent fan-out waves

| Wave | Run in parallel | Gated by |
|---|---|---|
| **W1** | T0.1 (then) T0.2 | — |
| **W2** | T1.1 + T1.2 | T0.* |
| **W3** | T1.3 | T1.1, T1.2 |
| **W4** | T2.1 (then) T2.2 | T1.3 |
| **W5** | **T3.0** | T2.1 |
| **W6** | T3.1 ∥ T4.1 | T3.0 (T4.1 also needs T2.1) |
| **W7** | T4.2 ∥ T4.3 | T4.1 |
| **W8** | Tier 5 cards as desired | MVP done |

Keep parallel agents on **disjoint files** (SPEC §layout). When two would touch the same file (e.g. the tool
switch in T2.2 vs T4.3), serialize them or have one own the file and the other hand off a patch.

---

## 4. Verification loop (every card)

1. **Build Debug AND Release** on an iOS sim (Release proves nothing leaked outside `#if DEBUG`).
2. **Realtime invariant audit:** grep the manager for the `response.create` symbol → **expect exactly 4** (SPEC N2).
3. **Secret scan:** grep the whole repo for `aiproxy`, `v2|`, `Bearer`, `sk-`, `ek_`, the bundle prefix → **expect 0** real values.
4. **Sim smoke:** launch, paste a test key, confirm the tier's acceptance criteria (greeting / captions / tool
   call / card / character pulse) via screenshot.
5. **No-audio-in-views check:** confirm no card/VC/`deinit` touches the session or audio (N4); confirm no level
   read goes through observation (N6).

---

## 5. What's already staged for you

- **`SPEC.md`** — architecture + the 6 invariants + the API truth + D1.
- **`research/01..07`** — the deep extraction/research per subsystem (cited).
- **`snippets/`** — 40 redacted, distilled starting files across `realtime / factory / spritekit / composition /
  config / keys / api-reference`. Treat them as **adapted references** (illustrative, not yet compiled against a
  real target) — wire them to the real types as you implement each card.
