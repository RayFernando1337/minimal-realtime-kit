# 03 — SpriteKit Character (extraction handoff)

> Worker slice: distill Pebbles' **procedural SpriteKit creature** (listens / speaks / reacts,
> driven by live audio level + a small state machine) into a clean, small MVP core for the
> minimal realtime kit. Source app: `OpenAIRealtimeSample/`. **No secrets in this slice**
> (the character is pure SpriteKit + Core Graphics; it touches no keys, URLs, or network).

---

## 0. Files read (complete) + line counts

| File | Lines | Role |
|---|---:|---|
| `OpenAIRealtimeSample/Pebbles/PebblesScene.swift` | **1416** | The whole rig: 9-stone cairn, textures, per-frame `update`, eyes, physics, hop, glance, sleep. |
| `OpenAIRealtimeSample/Pebbles/PebblesState.swift` | 105 | `PebblesState` (7 activities) + `PebblesTone` (4) + `PebblesEvent`. |
| `OpenAIRealtimeSample/Pebbles/PebblesView.swift` | 87 | SwiftUI `SpriteView` host; binds inputs to the scene. |
| `OpenAIRealtimeSample/Pebbles/PebblesLab.swift` | 236 | DEBUG harness that drives every input with no backend (optional). |
| `OpenAIRealtimeSample/Engine/AudioLevelMeter.swift` | 83 | Lock-guarded RMS meter; `level()` read once/frame. |
| `OpenAIRealtimeSample/App/StageHost.swift` | 15 | `UIViewControllerRepresentable` wrapper. |
| `OpenAIRealtimeSample/App/StageViewController.swift` | 776 | Full-screen `SKView` host (skimmed: only SKView wiring + how state/levels reach the scene). |
| `OpenAIRealtimeSample/Engine/PebblesHaptic.swift` | 63 | Tiny haptic cue enum (only `poke()` used by the scene). |
| `OpenAIRealtimeSample/DesignSystem/Theme.swift` (L36–45) | — | `UIColor(hex:)` convenience init (the scene's only design-system dependency). |
| `OpenAIRealtimeSample/Conversation/ConversationModel.swift` (L241–247) | — | `currentLevel()` — which meter feeds the scene per turn. |
| `OpenAIRealtimeSample/RealtimeManager.swift` (L35–36, 293, 339, 383) | — | The two meters + where they're fed (grep target). |

---

## 1. The minimal character contract

**Two inputs, one output.** This is the whole golden idea, and it is genuinely small.

- **Input A — discrete state** (`PebblesState`): `dormant · connecting · idle · listening · thinking · searching · speaking` (`PebblesState.swift:13-21`). Each maps to a *posture* via three derived knobs: `energy` (none/inward/outward, `:24-30`), `breathPeriod` seconds (`:43-51`), `baseScale` (`:53-62`). `confidence: high`
- **Input B — continuous amplitude 0…1**: a `levelProvider: () -> Float` closure stored on the scene (`PebblesScene.swift:26`), read **once per frame** in `update(_:)` and clamped (`:380`). `confidence: high`
- **Output — procedural motion**: positions/scales/eye-shapes eased toward per-state targets every frame. No sprite sheets; everything is computed (`PebblesScene.swift:8-11` header). `confidence: high`

There is also a small **orthogonal tone** input (`PebblesTone`: `neutral · warm · concerned · playful`, `PebblesState.swift:80-82`) that *tints* the look (e.g. `playful` → sustained smile + hop). It's optional for MVP.

### Exactly how state + level map to animation

**State → posture** is one pure function: `StateLook.make(state:tone:)` (`PebblesScene.swift:1352-1414`). It returns a `StateLook` value struct (`:1321-1346`) of animation knobs. The reduced/essential subset:

| State | baseScale | breath (s) | energy | eyes | extra posture |
|---|---:|---:|---|---|---|
| `dormant` | 0.82 | 10 | none | **closed** | low/wide heap (`spread 1.34, flattenY 0.5, rise -30, headDrop 13, tilt -0.17`), faint warm dim (`desaturate 0.13`) |
| `connecting` | 0.92 | 6 | none | half | inward gather (`spread 0.8`) |
| `idle` | 1.0 | 6 | none | open | content squat (`uprightness 0.12, flattenY 0.9`), occasional settle |
| `listening` | 1.03 | 4 | **inward** | wide | leans toward you (`lean 8, rise 10`), sits up (`uprightness 0.3`) |
| `thinking` | 1.0 | 5 | none | up | perk + tilt head, one stone bobs (`liftIndex 3`) |
| `searching` | 1.0 | 5 | none | up | look up + gentle orbit "dance" (`orbit + counterOrbit`) |
| `speaking` | 1.05 | 3 | **outward** | open | pops taller (`spread 1.08, rise 14`), 1–2 stones hop (`bounce 1`), smile on peaks |

(Source values: `PebblesScene.swift:1358-1396`; breath/scale/energy from `PebblesState.swift:43-62`.) `confidence: high`

**Amplitude → motion** happens per-frame in `update` and is gated by the state's `energy`:

- **Global scale pulse** (`PebblesScene.swift:411-419`):
  - `outward` (speaking): `ampScale = amp*0.09 + (bounce>0 ? |sin(t*7)|*amp*0.05 : 0)` → swells OUT, with a fast voice flutter.
  - `inward` (listening): `ampScale = -amp*0.04` → draws IN as you speak.
  - `none`: `0` (idle/thinking/etc. ignore amplitude).
  - final: `clusterScale = baseScale*(1 + breath*0.015 + pulse) + ampScale`.
- **Per-element energy** (`:532-541`): inward shrinks offsets `*(1-amp*0.05)`; outward expands `*(1+amp*0.06)` and makes hop stones bob `sin(t*8+phase)*(amp*11+2)*bounce`.
- **Smile on voice peaks** (`:921-931`): while speaking, `amp > 0.42` snaps eyes to a happy crescent (`crescentHold=1`), decaying over `0.45s`. `playful` tone holds the smile regardless of amplitude (`crescentSustained`).

So the contract in one sentence: **state picks the pose + whether amplitude pushes the body OUT (speaking) or IN (listening); amplitude scales that pose every frame and triggers the smile on loud peaks; everything else is a slow breath + blink.** `confidence: high`

**Always-present life (state-independent):** a slow breath sinusoid `sin(t·2π/breathPeriod)` scaling the body ±1.5% (`:381, :419`) and an asymmetric blink (fast close 70ms, slow open 210ms) on a 2.8–5.5s random timer (`:960-975`). These two cheap loops are most of what makes it read "alive."

---

## 2. Essential rig vs. elaborate extras (MVP vs. stretch)

PebblesScene is large because it is a **9-stone structured cairn** with full physics, a Pixar hop, and a card-aware glance. The believable core is much smaller. Honest split:

### MVP — keep (this is the "alive" minimum)
- **One per-frame `update` clock** reading `amp = levelProvider()` (`:374-380`). `confidence: high`
- **`StateLook.make` pure function** state→pose (`:1352-1414`), reduced to ~6 knobs (scale, squashY, rise, lean, eyes, energy). `confidence: high`
- **Amplitude → body scale** out/in by `energy` (`:411-416, 532-536`). `confidence: high`
- **Breath sinusoid** (`:381, 419`) + **eased transitions** (lerp toward targets each frame, e.g. `:578-580, 989-994`). `confidence: high`
- **Two eyes** = openness per state + asymmetric blink + idle look-around (`:947-995`). The eyes do the emotional work (`:8`). `confidence: high`
- **`reduceMotion` gate** (`:28, 356-363`) — accessibility; cheap to keep. `confidence: high`
- **A single body** — either a procedural orb (one radial-gradient texture) **or** a tiny 3-stone cluster. `confidence: med` (a single orb is enough; see "honesty" below).

### Stretch — cut for MVP (delightful, not essential)
- **9-stone cairn layout** + per-stone roles/asymmetry (`:227-314`, `clusterGeometryScale :75`). `confidence: high`
- **Elaborate CG stone textures**: 5 variants with mottling, 200-dot speckle, AO, terminator rim, matte sheen (`makePebbleTexture :1149-1255`, `stoneToneVariant :207`). A flat gradient or even an `SKShapeNode` circle reads fine for MVP. `confidence: high`
- **Physics poke → tumble → reassemble** (`didMove` world/gravity/edge-loop `:213-221`; `poke()` impulses `:1025-1050`; `endPhysics :1052-1060`). `confidence: high`
- **Drag → pickup → stack** (`beginDrag/updateDrag/endDrag :1091-1128`). `confidence: high`
- **Pixar happy-hop cycle** (anticipation→launch→hang→fall→land, `advanceHop :683-721`) + **pebble toss** (`:515-529`) + **hop sparkle** (`emitHopSparkle :725-741`). `confidence: high`
- **Per-stone damped springs** (`stoneVel :137, :556-567`) — adds weight/overlap; meaningless with one body. `confidence: high`
- **React-to-elements glance (P9)** + anticipatory `lookUp` + search wind-up (`:743-844, 630-643, 780-784`) — needs a card/surface system to point at (out of scope here). `confidence: high`
- **Transient envelopes**: wake-stretch (`:618-628`), poke-squash (`:603-613`), idle settle/shuffle (`:645-662`). `confidence: high`
- **Dormant "z z z" sleep cues** (`:846-914`) + **ground cast shadow** (`:307-313, 588-596`). `confidence: high`
- **Searching orbit/counter-orbit dance** (`:492-508`). `confidence: med`
- **Full tone system** — keep 0–1 tones (e.g. `playful` smile) or cut entirely. `confidence: med`

### Honesty: what cutting costs you
The "alive" feel comes ~80% from **(1) breath, (2) blink + eye look-around, (3) amplitude scale pulse, (4) eased posture changes, (5) the smile on speaking peaks** — all MVP-cheap and preserved by an orb+2-eyes. The cairn's *weight and overlap* (springs, lag stones, AO crevices) and the *poke-tumble / happy-hop* are real charm but are **delight, not legibility** — you can ship the agent's listen/think/speak read without them and add them back as a "stretch" pass. Losing the **glance/lookUp** loses "it noticed the card," but that behavior only matters once a card surface exists (worker 02/04). `confidence: med`

---

## 3. The per-frame hot path (the performance lesson)

**Audio amplitude is pulled, not pushed.** This is the single most important architectural lesson in this slice.

- The scene exposes `levelProvider: () -> Float` (`PebblesScene.swift:26`) and reads it **once per `update(_:)`** (`:380`) inside SpriteKit's own 60fps render loop (`view.preferredFramesPerSecond = 60`, `:216`).
- The host binds that closure to the meter and **explicitly keeps it off SwiftUI/observation**:
  - `PebblesView.swift:83` → `scene.levelProvider = level` (a closure, not `@State`).
  - `StageViewController.swift:228` → `pebblesScene.levelProvider = { [weak conversation] in conversation?.currentLevel() ?? 0 }`, with the comment *"Live voice level is sampled per-frame in the scene (kept OFF observation/layout)."* (`:227`).
- **Discrete** state/tone go through observation; **continuous** level never does. The UIKit `updateProperties()` reads only `conversation.state`/`tone` and re-applies the pose (`StageViewController.swift:187-217`, esp. `:193-195`) — its comment header says *"Observation (discrete state/tone only — never the audio meter)."* (`:187`). SwiftUI mirror: `PebblesView` only re-applies on `onChange(of: state/tone/reduceMotion)` (`PebblesView.swift:60-76`). `confidence: high`
- The **meter** is O(1) and thread-safe: `AudioLevelMeter.level()` returns a value behind an `OSAllocatedUnfairLock` (`AudioLevelMeter.swift:18-31`). Producers (mic buffers, decoded TTS PCM) write off the main thread via `ingest…` + an attack/release envelope (`:36-82`); the render tick just reads. `confidence: high`
- The scene **owns its own clock**, so it keeps breathing/pulsing even when SwiftUI isn't re-rendering (`PebblesView.swift:6-8` header). `confidence: high`

**Why it matters:** routing a 60Hz amplitude signal through SwiftUI `@Observable`/`@State` (or UIKit `updateProperties`) would invalidate the view graph **every frame** → layout thrash + battery + jank. A pull-based closure read inside the SK loop is zero view-tree churn and is the reason the character animates smoothly under load. **Replicate this exactly:** state/tone = observation; amplitude = a closure read in `update`. `confidence: high`

Which meter is read is turn-aware (`ConversationModel.currentLevel()`, `:241-247`): `listening → micMeter.level()`, `speaking → pebblesMeter.level()`, else `0`. The two meters are fed in `RealtimeManager` (mic buffers `:293`; base64 TTS PCM `:339`; reset on turn end `:383`). `confidence: high`

---

## 4. Dropping it into a fresh project

**Dependencies: essentially none beyond Apple frameworks.**

- **Frameworks:** `SpriteKit`, `UIKit` (for `UIGraphicsImageRenderer` textures + `UIColor`), `Accelerate` + `AVFoundation` (only for the meter's `vDSP_rmsqv` / `AVAudioPCMBuffer` ingest), and optionally `SwiftUI` for the `SpriteView` host. No third-party packages. **No AIProxy.** `confidence: high`
- **Assets:** **none.** No sprite sheets, no image atlases, no bundled fonts. All textures are drawn at runtime with Core Graphics (`makePebbleTexture/makeShadowTexture/makeEyeTexture :1149-1310`). The only text glyph is the dormant "z" rendered with `UIFont.systemFont` (`:888-900`) — a system font, no asset (and "z" is a stretch cut anyway). `confidence: high`
- **Tiny internal deps to copy or inline:** `UIColor(hex:)` (`Theme.swift:36-45`) and (optional) `PebblesHaptic.poke()` (`PebblesHaptic.swift:28`, just `UIImpactFeedbackGenerator(style:.light).impactOccurred(intensity:0.6)`). Both are reproduced in the snippets. `confidence: high`

**Wiring (4 steps):**
1. Create the scene; set `scene.scaleMode = .resizeFill`, `backgroundColor = .clear`.
2. Present in an `SKView` with `allowsTransparency = true` / `isOpaque = false` (`StageViewController.swift:254-264`) — or a SwiftUI `SpriteView(scene:options:[.allowsTransparency])` (`PebblesView.swift:40`).
3. `scene.levelProvider = { meter.level() }` — bind the closure once (re-bind if identity changes, per `PebblesView.swift:79-86`).
4. On state/tone change, call `scene.apply(state:tone:)` (`PebblesView.swift:60-63` / `StageViewController.swift:193-195`). Drive amplitude entirely through the closure — never per-frame `apply`.

The included `CharacterView.swift` snippet is a ~40-line SwiftUI host that does all four; `PebblesLab.swift` (`:70-209`) shows you can exercise all 7 states + tone + amplitude slider + poke **with no backend** (great for a demo/preview target). `confidence: high`

---

## 5. Source map (exact `file:line`)

**`PebblesScene.swift` (1416 lines):**
- Inputs: `levelProvider :26` · `reduceMotion :28` · `onPoke :30` · `reactToElements :33`
- Rest anchor / scale: `restAnchorNormalized :41` · `restCenter :50-53` · `clusterGeometryScale :75`
- Stones model + build: `struct Stone :57-63` · `buildStones :227-314` (layout `:242-252`) · `attachEyes :316-325` · `makeEye :327-347`
- State apply: `apply(state:tone:) :351-370` · `StateLook :1321-1346` · `StateLook.make :1352-1414` · `idle :1348-1350`
- **Per-frame `update` :374-599** (clock `:374-378`, amp `:380`, breath `:381`, alpha/desat ease `:384-385`, ampScale `:411-416`, clusterScale `:419`, center/clamp `:431-462`, per-stone loop `:464-586`, springs `:556-567`, scale/squash `:572-580`, ground shadow `:588-596`, eyes `:598`)
- Eyes: `applyEyes :918-996` (crescent `:921-945`, eye-shape switch `:951-958`, blink `:960-975`, gaze `:984-995`) · `setEyeStyle :998-1021` · eye paths `:192-198`
- Envelopes: pokeSquash `:603-613` · wakeStretch `:618-628` · searchWindUp `:633-643` · shuffle `:645-662`
- Happy-hop: `HopFrame :670-677` · `advanceHop :683-721` · `emitHopSparkle :725-741` · tossStones `:117`, `:515-529`
- Glance (P9): `glance :751-773` · `lookUp :780-784` · `advanceGlance :791-834` · `clearGlance :837-844`
- Sleep cues: `startSleepCues/stopSleepCues :850-862` · `buildSleepZ :866-876` · `emitZ :902-914`
- Physics: `didMove :213-221` · `touchesBegan :1025-1027` · `poke :1029-1050` · `endPhysics :1052-1060`
- Hit-test / drag (stage seam): `stoneHit :1066-1075` · `beginDrag/updateDrag/endDrag :1091-1128`
- Textures (generated once): `pebbleTextures :204` · `makePebbleTexture :1149-1255` · `makeShadowTexture :1260-1280` · `makeEyeTexture :1285-1310` · `stoneTone :1134-1142`

**`PebblesState.swift` (105):** state enum `:13-21` · `Energy` `:22` / `energy` `:24-30` · `usesVoiceAmplitude :33` · `isActive :35-40` · `breathPeriod :43-51` · `baseScale :53-62` · `statusLabel :65-75` · `PebblesTone :80-82` · `PebblesEvent :86-105`.

**`PebblesView.swift` (87):** scene `@State` factory `:32-37` · `SpriteView :40` · a11y `:41-53` · `onAppear :54-59` · `onChange(state/tone/reduceMotion/scenePhase) :60-76` · `pushInputs (bind closures) :82-86`.

**`AudioLevelMeter.swift` (83):** lock + envelope init `:18-28` · `level() :31` · `reset() :34` · `ingest(samples:) :36-41` · `ingest(buffer:) :44-58` · `ingestPCM16(base64:) :61-74` · `apply(rms:) (dB→0..1 + attack/release) :76-82`.

**`StageViewController.swift` (776, skimmed):** `skView :93` · `pebblesScene :94` · `configureScene :221-238` (levelProvider bind `:228` + off-observation comment `:227`, reduceMotion `:229`, restAnchor `:237`) · `installSKView :254-264` (`presentScene :259`) · pose on appear `:175` · `updateProperties` discrete-only `:187-217` (`apply :195`) · restAnchor from reservation `:458-460` · `lookUp :480` / `glance :510, 519` · reduceMotion observer `:584-592`.

**`StageHost.swift` (15):** `UIViewControllerRepresentable :7-15`.
**`PebblesLab.swift` (236):** state/tone lists `:22-25` · interactive view `:70-209` · level closure `:120` · poke `:136` · amplitude slider `:181-187` · previews `:213-235`.
**`ConversationModel.swift`:** `currentLevel() :241-247`.
**`RealtimeManager.swift`:** meters declared `:35-36` · mic ingest `:293` · TTS ingest `:339` · reset `:383, 419-420, 463-464`.
**`PebblesHaptic.swift`:** `poke() :28` · primitives `:56-62`.
**`Theme.swift`:** `UIColor(hex:) :36-45`.

---

## Snippets produced (REDACTED, under `snippets/spritekit/`)
- `MinimalCharacterScene.swift` — reduced scene: **1 procedural orb + 2 eyes**, per-frame `update` reading `levelProvider`, state→pose, amplitude in/out, breath, blink, smile-on-peak, `reduceMotion`. (Adapted from `PebblesScene.swift`; cairn/physics/hop/glance removed.)
- `CharacterState.swift` — minimal `CharacterState` (7 cases) + `CharacterTone` + the `CharacterLook` pure function. (From `PebblesState.swift` + `StateLook.make`.)
- `AudioLevelMeter.swift` — the meter, near-verbatim (already clean, key-free).
- `CharacterView.swift` — ~40-line SwiftUI `SpriteView` host. (From `PebblesView.swift`.)
- `README.md` — how the four fit + the 4-step drop-in + the hot-path rule.

No real keys/URLs exist anywhere in this slice; nothing required redaction beyond renaming `Pebbles*` → `Character*`.
