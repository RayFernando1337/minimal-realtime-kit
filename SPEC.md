# SPEC — Minimal GPT Realtime Voice Agent (open-source)

> Synthesized from 7 parallel research/extraction workers (see `research/01..07`). Every section
> cites its backing research file. **Confidence is carried through**: API facts are live-doc-cited
> (high); architecture facts are source-cited (high); the build-path recommendation (D1) is a
> judgment call (flagged).
>
> **What this is:** the spec for a brand-new, clonable, **bring-your-own-key** iOS app that gives you
> a real-time **voice agent that calls tools**, distilled from the Pebbles app
> (`OpenAIRealtimeSample/`). **None of Ray's keys ship.**

---

## 1. Vision & scope

A person opens the app, taps once, and **talks** to an agent that answers in a natural voice, can be
interrupted (barge-in), **calls tools**, and (optionally) **draws cards** and is embodied by a small
**living character**. The repo's job is to be the smallest thing that teaches those patterns well, so
people can fork it and experiment the day they clone it.

**The golden parts we are preserving** (why this repo is worth open-sourcing):
1. **Realtime voice that feels like an agent** — always-open mic, semantic VAD, barge-in. *(research/01)*
2. **Tool calling with discipline** — the **one-`response.create`-per-turn** invariant, and the
   inline-vs-deferred (slow-tool) split. *(research/01)*
3. **Agent-driven UI via a data-only factory** — the model picks a versioned id + typed payload
   (**data, never code/behavior**) and the app renders a card with a **total mandatory fallback**. *(research/02)*
4. **An audio-reactive SpriteKit character** — amplitude pulled once per frame, off observation. *(research/03)*

**Explicitly OUT of scope for v1** (all easy to layer back — they're documented in the research):
on-device memory store, the OpenClaw "deeper brain" consult, the collect-board / pocket / park /
resurface surface lifecycle, conversation history & hub, tone inference, latency tracing, 6 of the 9
component bodies, and the SpriteKit physics/cairn/hop/glance flourishes.

---

## 2. Non-negotiables (invariants the build must hold)

| # | Invariant | Source |
|---|---|---|
| N1 | **No secret ships.** Zero API keys / partial keys / service URLs / Team IDs in the repo. BYO-key only. | research/05, 07 |
| N2 | **Exactly one `response.create` per tool turn.** A bare `conversation.item.create` (tool output / user item / system note) triggers NO response — only `response.create` does. | research/01 |
| N3 | **Total mandatory fallback.** Unknown component id / malformed payload / throwing builder / nil tool call → a fallback card. The agent can never crash or wedge the UI. The model passes **data, never behavior**. | research/02 |
| N4 | **A view/VC never owns audio or the session.** Audio + session are owned by the realtime manager / conversation model; a card deallocating must never tear down audio. | research/04 |
| N5 | **One event stream, one drainer.** `nonisolated AsyncStream<PebblesEvent>` from the actor → a single `@MainActor` consumer. | research/01, 04 |
| N6 | **Audio level is read per-frame, OFF observation.** Only discrete state/tone go through observation; ~50×/s amplitude is pulled in the SpriteKit `update` loop. | research/03, 04 |

---

## 3. Target stack & key decisions

| Thing | Decision | Confidence |
|---|---|---|
| **Model** | `gpt-realtime-2` (current flagship, GPT-5-class, 128K ctx, `reasoning.effort`; launched May 2026). Voice `marin` or `cedar`. Confirm the exact dated snapshot in the dashboard before pinning. | high *(research/06)* |
| **Language / UI** | Swift, iOS. UIKit owns composition; SwiftUI hosts leaf bodies; SpriteKit is the character. | high *(research/04)* |
| **iOS target** | **Default iOS 26** (matches source; gets liquid-glass `UIGlassEffect` + iOS-26 auto-observation, least porting). *Documented option:* lower to iOS 18 for reach (swap glass→material, add manual `withObservationTracking`). | med *(research/05)* |
| **Dependency** | v1: **AIProxySwift `0.153.0`** (MIT) in **direct BYO-key mode** — see D1. | high *(research/05, 07)* |
| **Keys** | Paste-your-own-key → **Keychain** (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), behind a `RealtimeCredentialProvider` seam. Optional ephemeral-token backend documented. | high *(research/07)* |

### D1 — Transport / SDK (the one decision worth Ray's confirmation)

There are two viable paths; the research supports a **phased default**:

- **v1 default — AIProxySwift in direct BYO-key mode** (`AIProxy.openAIDirectService(unprotectedAPIKey:)`).
  Reuses the proven `RealtimeManager` **and its `AudioController`** (mic capture, PCM16 24 kHz, echo
  cancellation, playback, barge-in truncation). That audio layer is **not in our repo — it's SDK-provided**
  *(research/01)* — and getting it wrong is the **VPIO-crash** landmine. One MIT SPM dep, fastest path to
  "experiment today." **Caveat:** AIProxySwift's GA-config migration is in progress (issue #268); pin the
  version and verify its realtime session config maps to the GA surface in §11.
- **v2 north-star — hand-rolled `URLSessionWebSocketTask` + ephemeral `ek_…` tokens**, zero dependencies,
  exact GA surface, ephemeral-first. **Cost:** you must reimplement the AudioController (AVAudioEngine 24 kHz
  PCM16 + echo cancel + playback). *(research/06, 07)*

**Recommendation:** ship **v1 on AIProxySwift-BYOK** to get a working, low-risk voice+tools demo fast,
then offer **v2 raw-WS** as the dependency-free upgrade. This honors "minimum viable, experiment today"
while keeping the door open to the clean OSS core. **Override welcome** — if you'd rather lead with the
zero-dep raw-WS core, the plan's Phase 1 swaps accordingly (research/06 already supplies the WS snippets).

### D2 — Keys (no backend required for v1)

Ship **paste-your-own-key**: the user enters their OpenAI key once; it's stored in the **Keychain** and
used by the credential provider. Ray ships nothing. For v1 (AIProxySwift-BYOK) the pasted key is used
directly on-device (a standing key on the *user's own* device — fine for BYO experimentation). For v2 the
same provider mints a short-lived `ek_…` token (on-device, or via the optional ~15-line Cloudflare
Worker / Node backend in `snippets/keys/`). *(research/07)*

---

## 4. Architecture (the spine)

```
@main App
  └─ CompositionRoot            (DI singleton; owns ConversationModel + SurfaceStore; registerComponents())
       └─ StageHost             (UIViewControllerRepresentable: SwiftUI → UIKit)
            └─ StageViewController        (coordinator: reversed-priority hitTest, observation→scene/canvas bridge)
                 ├─ StageBackground       (BEHIND — gradient/frost)
                 ├─ SKView(CharacterScene)(the SpriteKit character, full-screen, taps pass through)
                 ├─ FloatingCanvas        (hosts the agent-driven cards)
                 └─ StageForeground       (captions, connect/stop/mute control)
```

**Why UIKit owns composition** *(research/04)*: a full-screen SwiftUI `UIHostingController` is *greedy* in
`hitTest` (ignores content), so a UIKit root runs **reversed-priority** routing — cards → character →
foreground — letting taps reach the character behind the greedy host. This is non-negotiable if you keep
the card+character sandwich.

**End-to-end data flow** *(research/01, 02, 04)*:
```
realtime tool event (e.g. render_component)
  → RealtimeManager.emit(.component) on @AIProxyActor
  → AsyncStream<PebblesEvent>
  → ConversationModel.apply() on @MainActor (the SOLE drainer)
  → componentSurfaceRouter → SurfaceStore.present()
  → StageViewController.updateProperties() (iOS-26 observation)
  → FloatingCanvas.sync() → ComponentFactory.make() → FactoryContext.host()
  → CardViewController (glass card)
```

**The actor split** *(research/01)*: `RealtimeManager` is `@AIProxyActor` (one global actor; the whole
realtime + tool loop runs there, one turn at a time). It exposes a `nonisolated AsyncStream<PebblesEvent>`.
`ConversationModel` is `@MainActor @Observable`, the single drainer and the actor↔UI bridge. The project
sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

---

## 5. The realtime core contract *(research/01 → snippets/realtime/)*

**Lifecycle:** `connect → session config → mic stream loop → receiver loop → state emit → stop`. The
receiver `switch` is a 1:1 map from SDK events to a discrete `PebblesState` (connecting / idle / listening
/ thinking / speaking / searching / dormant).

**N2 in practice — the 4 `response.create` sites** (reduced from the source's 4; keep them by symbol, not
line number):
1. **greeting** — `aiSpeaksFirst` fires one on `sessionUpdated`.
2. **`sendUserChoice`** — a card tap = a NEW user turn (a `role:"user"` item + at most one `response.create`,
   guarded by `responseInFlight`).
3. **shared deferred tail** (`completeDeferredToolTurn`) — the ONE site every slow/network tool funnels through.
4. **inline tail** — fast/local tools fall through to this single send.

**The double-fire guard:** `responseInFlight` is set **before** every send (pairs with server-VAD
`createResponse:true`) so a second `response.create` is never issued while one is active.

**`sendContextUpdate`** appends a declarative `role:"system"` item and sends **no** `response.create` — it
keeps the model's working context honest without taking a turn.

---

## 6. Tool calling *(research/01 → snippets/realtime/02-tool-dispatch.swift, 04-tool-schemas.swift)*

**The dispatch contract:** `response.function_call_arguments.done` → decode args (lenient; bad payload =
graceful no-op, never a throw) → fulfill → send `function_call_output` (+ optional system context note) →
the single `response.create`.

**The inline-vs-deferred rule:** slow/network tools (`web_search`) **must** run in a detached `Task` and
finish through the shared deferred tail (so audio keeps flowing and they add no `response.create` of their
own). Fast/local tools fall through to the inline tail.

**MVP tool set (3):**
| Tool | Why | Note |
|---|---|---|
| `get_time` | trivial **inline** example — proves the loop with zero network | new, ~10 lines |
| `web_search` | the **deferred/slow** teacher | **client function**, NOT a hosted tool. OpenAI has **no native realtime `web_search`** *(research/06)* — and the SDK's `.webSearch` case is a conflicting trap *(research/06, 07)*. Make it BYO/optional or stubbed; optionally delegate to the Responses API or a user-configured search key. |
| `render_component` | the **factory** showcase (data-not-behavior) | see §7 |

**Cut for v1:** `remember/forget_about_user`, `consult_openclaw`, `dismiss/collect/park/clear_notes`.

**"How to add a tool":** add a JSON schema + a `case` in the dispatch switch; fast → inline, slow →
detached `Task` + deferred tail. Never add a 5th raw `response.create`.

---

## 7. The factory pattern *(research/02 → snippets/factory/)*

Registry → versioned id enum (`"note.v1"`) → opaque `JSONValue` payload re-decoded into a typed struct →
builder (`decode → validate → context.host(body)`) → card VC, with **N3's total fallback** at every seam.
Behavior is a **typed closure** the app owns (e.g. `choice` wires `onUserChoice`; a pick = a new user turn),
never model code. The `render_component` tool's id enum is **derived from `ComponentID.allCases`**, so the
schema can't drift from the registry.

**Correction (code wins over stale docs):** the registry is a plain dict — **NOT compiler-enforced**; a
forgotten `register()` **silently** routes to the fallback. (`AGENTS.md`'s "ComponentFactory is
compiler-enforced" is stale; the *board* switch is the enforced one.) **MVP fix:** a launch-time
`assertAllRegistered()` over `allCases`. *(research/02)*

**MVP components (3):** `note` (flat, lenient, show-only), `choice` (interactive — proves data-not-behavior
+ the new-user-turn flow), `statCard` (nested payload + validation). **Cut (show-only, easy re-add):**
`list`, `lineChart`, `donutChart`, `activityRings`, `imageCard`, `progressSteps`. **Also drop for v1:** the
collected/board seam (no board) and `render_hint`.

---

## 8. The character *(research/03 → snippets/spritekit/)*

**Contract:** 2 inputs → 1 output. Inputs = (a) discrete state and (b) a continuous amplitude `0..1`;
output = procedural motion via a pure `StateLook.make(state)` function. **Hot path (N6):** amplitude is
**pulled once per frame** in the SpriteKit `update` loop via a `levelProvider` closure, kept entirely off
SwiftUI/observation; only state/tone go through observation. Two meters, turn-aware: a `currentLevel()`
picks mic energy (listening) vs TTS energy (speaking).

**MVP rig:** a single orb + 2 eyes that pulse with amplitude (speaking swells out, listening draws in),
breath sinusoid, eased state transitions, asymmetric blink, `reduceMotion` support. Zero assets/fonts (all
Core-Graphics textures at runtime). **Cut → stretch:** the 9-stone cairn, per-stone springs, physics
poke/tumble, happy-hop, react-to-card glance, sleep "z z z". (~80% of the "alive" feel survives the cut;
what's lost is *weight/overlap* charm and *delight*, not listen/think/speak legibility.)

---

## 9. Composition & surfaces *(research/04 → snippets/composition/)*

Keep the **sandwich spine** (§4) and a **minimal `SurfaceStore`** (~110 lines from 1,492): a floating-card
list + `present` / `dismiss` / `bringToFront`. `FloatingCanvas` syncs the store to `CardViewController`s
(glass host + drag + a transform-free **size cache** — `UIHostingController` intrinsic size corrupts under
an ancestor scale transform, the documented card-sizing landmine). Captions + the connect/stop/mute control
live in `StageForeground`.

**Cut for v1:** collect board, float⇄collect match-move, pocket drawer, park/resurface, hub, conversation
history, persistence, auto-expiry, the ~25 DEBUG seeders. Net spine ≈ 800–900 lines (from ≈4,900).

---

## 10. Keys, config & build *(research/05, 07 → snippets/config/, snippets/keys/)*

**Secrets to strip (4, all in `RealtimeManager.swift`):** OpenAI AIProxy partial key + service URL
(`:182-183`), Exa AIProxy partial key + service URL (`:862-863`). **Also scrub** 2 Apple Team IDs and the
`com.rayfernando.*` bundle id from the project. **Do NOT copy the source `.xcodeproj`/`.pbxproj`** — start a
fresh project (it carries Team IDs/bundle id). Gitignored-but-on-disk files (`*.local.xcconfig`,
`*.local.swift`) must never be copied.

**Build settings the new project needs:** iOS deployment target (§3); `INFOPLIST_KEY_NSMicrophoneUsage​Description`;
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; `GENERATE_INFOPLIST_FILE = YES`; `PBXFileSystemSynchronizedRootGroup`
(new files auto-include — never hand-edit the pbxproj); one SPM dep (AIProxySwift). Fonts optional (DM Serif /
Hanken are OFL — ship the license if kept; or drop for system fonts).

**Key plumbing (templates provided):** `Secrets.xcconfig.example` + `gitignore.template` +
`SecretsReader.swift.example` (config path), and `KeychainStore.swift` + `RealtimeCredentialProvider.swift`
+ `EphemeralTokenClient.swift` + `mint-token.{worker.js,node.js}` (the paste-key + optional-backend path).

---

## 11. Latest OpenAI Realtime API reference *(research/06 → snippets/api-reference/)*

The current GA truth a builder must match (all live-doc-cited in research/06):

- **Model:** `gpt-realtime-2` (real & current). Voices lowercase incl. `marin`, `cedar` (locked after first audio).
- **Transport:** **WebRTC** is OpenAI's recommended *client* transport (`POST /v1/realtime/calls`, events over
  an `oai-events` data channel); **WebSocket** is fine for a zero-dep core (you own AVAudioEngine).
- **Auth:** ephemeral client secrets via **`POST /v1/realtime/client_secrets`** (mint with a standard key;
  returns `value` = `ek_…`; TTL 10–7200 s, default 600). **Never ship a standing key.** (Beta
  `/v1/realtime/sessions` is retired.)
- **Session config is now NESTED:** `session.type:"realtime"`, `output_modalities`,
  `session.audio.input/output.format` (`audio/pcm`@24k), `audio.input.turn_detection`
  (`server_vad` | `semantic_vad` w/ `eagerness` | `null`), `audio.input.transcription`,
  `audio.output.voice/speed`, `max_output_tokens`, `reasoning.effort`.
- **Tools:** client `function` loop = `response.function_call_arguments.done` →
  `conversation.item.create{function_call_output}` → `response.create`. Realtime also supports API-executed
  `mcp` tools/connectors. **No native hosted `web_search`.**
- **What changed vs the 2025 baseline:** beta interface + all `gpt-4o-realtime-preview*` shut down 2026-05-07;
  renames: `modalities`→`output_modalities`, `voice`→`audio.output.voice`,
  `input_audio_format`→`audio.input.format`, `turn_detection`→`audio.input.turn_detection`,
  `response.audio.delta`→`response.output_audio.delta`, etc. (full table in research/06).

**Confirm before pinning** (research/06 open items): exact dated snapshot string; `response.audio.delta`
vs `response.output_audio.delta` against the live server-events ref; the SDK's `.webSearch` actual behavior.

---

## 12. Open decisions & things to confirm

- **D1 (Ray's call):** lead with AIProxySwift-BYOK (recommended) or raw-WS? Default = AIProxySwift-BYOK v1. *(§3)*
- **Confirm against live dashboard/docs** before pinning: dated model snapshot; audio-delta event name; the
  ephemeral mint response field; whether to keep AIProxySwift past v1 given its in-progress GA migration. *(research/06, 07)*
- **iOS target:** 26 (default, liquid glass) vs 18 (reach). *(§3)*
- **Naming:** the repo/product name (this folder name is provisional).

---

## 13. Proposed repo layout (new repo)

```
<NewRepoName>/
├── README.md  (BYO-key setup, run, the one-response.create rule)
├── .gitignore  (from snippets/config/gitignore.template)
├── Config/Secrets.xcconfig.example
├── <App>.xcodeproj
└── <App>/
    ├── App/            OpenAIRealtimeApp.swift, CompositionRoot, StageHost, StageViewController, SwiftUIViewController
    ├── Realtime/       RealtimeManager (@AIProxyActor), ConversationModel, PebblesEvent/State, AudioLevelMeter
    ├── Keys/           KeychainStore, RealtimeCredentialProvider, (EphemeralTokenClient)
    ├── Factory/        ComponentID, ComponentPayloads, ComponentFactory, FactoryContext, FallbackComponentVC,
    │                   NoteComponent, ChoiceComponent, StatCardComponent, Registration(+assertAllRegistered)
    ├── Character/      CharacterScene (SpriteKit), CharacterState, CharacterView
    └── Stage/          SurfaceStore (minimal), FloatingCanvas, CardViewController, StageForeground/Background, CaptionsView
```

## 14. Provenance

| Section | Backing research |
|---|---|
| Realtime core, tools, event bridge | `research/01-realtime-core.md` |
| Factory pattern | `research/02-factory-pattern.md` |
| Character | `research/03-spritekit-character.md` |
| Composition & surfaces | `research/04-composition-surface.md` |
| Keys, config, build, secrets-to-strip | `research/05-config-keys-build.md` |
| Latest OpenAI Realtime API | `research/06-openai-realtime-api.md` |
| SDK + BYO-key decision | `research/07-aiproxy-byok-keys.md` |
