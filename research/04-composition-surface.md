# 04 — App Composition + Surface ("cards on glass") Architecture

> **Slice:** the UIKit-owns-composition / SwiftUI-hosts-leaves / SpriteKit-is-character **sandwich**,
> the **DI root**, and the **card surface model**. Source app: Pebbles
> (`OpenAIRealtimeSample/`). Goal: find the **minimal viable spine** for a clone.
>
> **Conventions:** every claim cites `file:line`; confidence tagged `[H]` high / `[M]` med / `[L]` low.
> Other subsystems (realtime core, factory bodies, SpriteKit character) are referenced **by name** —
> see slices 01 / 02 / 03. Redacted snippets: `../snippets/composition/`. **No secrets live in any
> file in this slice** (keys/URLs are confined to `RealtimeManager`, slice 01/07). `[H]`

---

## 0. TL;DR (the golden spine, in one breath)

`@main App` creates the **one** `ConversationModel` and calls `CompositionRoot.registerComponents()`
once → renders `StageHost` (a `UIViewControllerRepresentable`) `.ignoresSafeArea()` → which makes a
**`StageViewController`** that owns a 4-layer Z-stack ("sandwich"): SwiftUI **background** ‹ full-screen
**`SKView`** (character) ‹ passthrough **`FloatingCanvas`** (the cards) ‹ SwiftUI **foreground**
(captions + controls). UIKit owns it because a full-screen `UIHostingController` is *greedy* in
`hitTest`, so the only way to put a tappable character UNDER a full-screen SwiftUI UI is a UIKit root
view with **reversed-priority hit-testing**. State flows model→UI through iOS-26 **observation**
(`updateProperties()`), never through the audio meter. Cards are agent-driven: a tool event →
`ConversationModel` → a **router closure** → `SurfaceStore` (the single source of truth) →
`FloatingCanvas.sync()` → `ComponentFactory` → a `CardViewController`. `[H]`

---

## 1. The composition spine

### 1.1 The chain (`@main` → CompositionRoot → StageHost → StageViewController)

```
OpenAIRealtimeSampleApp (@main, SwiftUI)         OpenAIRealtimeSampleApp.swift:10-46
  ├─ @State conversation = ConversationModel()   ── the ONE process-lifetime model      :12
  ├─ init(): CompositionRoot.registerComponents()── stand up the factory registry once  :15-19
  └─ body → StageHost(...).ignoresSafeArea()     ── fill the window edge-to-edge         :43-44
       │
       ▼
CompositionRoot (enum, DI root)                  App/CompositionRoot.swift:9-91
  ├─ static let surfaceStore = SurfaceStore()    ── the ONE source of truth for surfaces :14
  └─ registerComponents()                        ── register .note (+ 8 more in full app):20-90
       │
       ▼
StageHost : UIViewControllerRepresentable        App/StageHost.swift:7-15
  └─ makeUIViewController → StageViewController(conversation, motion, surfaceStore)       :11-13
       │
       ▼
StageViewController : UIViewController            App/StageViewController.swift:73-776
  └─ loadView() = StageRootView() ; viewDidLoad() installs the sandwich                   :148-168
```

**DI is a singleton enum, not a container.** `CompositionRoot` is an `enum` with `static let`
members created lazily once and never re-instantiated; the comment is explicit that audio/session is
independent of any view's lifetime (`CompositionRoot.swift:4-14`). `[H]` The `@main` App owns the
`ConversationModel`/`MotionManager` as `@State` so they live for the process
(`OpenAIRealtimeSampleApp.swift:12-13`). `[H]` **Minimal version:**
`../snippets/composition/01-CompositionSpine.swift`.

### 1.2 The sandwich (Z-order, back → front)

Built in `StageViewController.viewDidLoad()` (`App/StageViewController.swift:150-168`): `[H]`

| Z | Layer | Type | Role | install @ |
|---|-------|------|------|-----------|
| 0 (back) | `backgroundHost` | `UIHostingController(StageBackground)` | living place + frost + arrival veil | `:240-252` |
| 1 | `skView` | `SKView(PebblesScene)` | the character, full-bleed (slice 03) | `:254-268` |
| 2 | `floatingCanvas` | `FloatingCanvasController` (`PassthroughContainerView`) | the cards on glass | `:270-280` |
| 3 (front) | `foregroundHost` | `UIHostingController(StageForeground)` | captions, controls, dormant wake-catcher | `:282-298` |
| 4 (overlay) | `collectBoard` | `CollectBoardController` | browse collected cards — **CUT for MVP** | `:300-317` |

Each layer is pinned full-bleed via a 4-constraint `pin(_:to:)` helper (`:612-621`). `[H]`

### 1.3 Why UIKit owns composition — the reversed-priority `hitTest` (load-bearing)

This is the single most important architectural reason, documented at length in the file header
(`App/StageViewController.swift:5-25`) and implemented in `StageRootView.hitTest`
(`:33-68`): `[H]`

- A `UIHostingController` claims its **whole bounds** in `hitTest` — Apple's docs say `hitTest`
  "doesn't take the view's content into account," so a single full-screen SwiftUI host is **greedy**
  and *cannot* be made to return `nil` over empty space (verified by their P2 diagnostic — no
  descendant subviews, opaque single sublayer) (`:11-19`). `[H]`
- Therefore to place a full-screen **SKView character UNDER** a full-screen SwiftUI UI and still let a
  tap on a *stone* reach the character, the UIKit root view runs **reversed priority**:
  1. **cards win first** (a card over a stone stays draggable) — via the passthrough canvas, which
     returns `nil` in empty space (`:58-63`);
  2. a **node-precise stone tap** → the `SKView` (`pebblesScene.stoneHit`) (`:64-65, 333-340`);
  3. **everything else** → `super.hitTest` → the greedy foreground host, which routes it internally
     via SwiftUI (`:66-67`). `[H]`
- The passthrough container's `nil`-in-empty-space behavior (`FloatingCanvas.swift:30-35`) is the
  hinge that makes the whole scheme work — without it the cards layer would also be greedy. `[H]`

**Minimal version** keeps steps 1–3 verbatim and a tap→poke; it drops the collect-board step-0 and
the character drag (slice 03): `../snippets/composition/02-StageViewController.swift`.

### 1.4 Model→UI bridge: observation, NOT the audio meter (a deliberate split)

`StageViewController.updateProperties()` (`App/StageViewController.swift:189-217`) reads the discrete
`@Observable` props (`conversation.state`, `.tone`, `surfaceStore.floatingSurfaces`); under iOS 26
automatic observation tracking this method is **re-invoked** whenever any read value changes, and it
then `pebblesScene.apply(...)` + `floatingCanvas?.sync()`. `[H]` The ~50×/s **audio meter is kept OFF
this path** — the scene samples it per-frame via a `levelProvider` closure
(`:228`, `configureScene` `:221-238`) so layout/observation never churns at audio rate (`:22-24`). `[H]`
This is the cleanest seam to copy: **discrete state → observation → sync; continuous level →
per-frame pull.**

---

## 2. The minimal surface model

### 2.1 What `SurfaceStore` is (and the 80% that's optional)

`Stage/SurfaceStore.swift` is **1492 lines** and is the "single source of truth for what's on the
glass" (`:5-17, 197-214`). It is a **lifecycle state machine** (`SurfaceState`:
`composed/floating/collected/parked/resurfaced/dismissed/expired`, `:28-36`) `[H]`. For the MVP only
**floating** + **present/dismiss** are needed; everything else is layered:

| Sub-feature | Lines | MVP? | Note |
|---|---|---|---|
| `Surface` value type (id/componentID/payload/zIndex/tilt/isFallback) | `88-139` | **KEEP** (trim) | the core record `[H]` |
| `@Observable` store + `floatingSurfaces` + `maxVisibleFloating=6` | `200-230` | **KEEP** | budget knob `[H]` |
| `present(request:)` / `composeNote` / `compose` | `449-534` | **KEEP** | the two entry points + fallback path `[H]` |
| `dismiss(id:)` / `bringToFront(id:)` / `nextZIndex` | `536-639` | **KEEP** | basic mutations `[H]` |
| the `gate(...)` (float vs collect vs deferred) | `433-443` | **SIMPLIFY** | MVP: float, drop oldest on overflow `[H]` |
| collected/parked states + collect/refloat/park/resurface | `653-857` | **CUT** | collect board + geofence/time park `[H]` |
| pocket collapse/restore (`isPocketCollapsed`, togglePocket) | `263-268, 859-875` | **CUT** | drawer affordance `[H]` |
| free placement / edge tuck (`NormalizedPoint`/`DockEdge`) | `65-119` | **CUT** (v2) | dropped-card-stays-put `[H]` |
| persistence (`PersistenceWriter`, back-compat decode, debounced save) | `277-431` | **CUT** (v2) | survives relaunch `[M]` |
| lazy auto-expiry clock | `945-986` | **CUT** | ~4h backstop `[H]` |
| agent dismiss/collect/park-by-title + `contextBlock()` | `551-943` | **CUT** | voice removal tools `[H]` |
| ~25 `#if DEBUG` seeders (`seedDemo*`) | `988-1491` | **CUT** | ≈⅓ of the file, screenshot QA only `[H]` |

**Minimal version:** `../snippets/composition/03-SurfaceStore.swift` (≈110 lines vs 1492). `[H]`

### 2.2 The two entry points (how a tool event becomes a card)

- **`composeNote(content:)`** (`:449-457`) — the `surface_note` parity path; builds the `{title,
  kind, meta}` note payload so the registered `.note` body renders. `[H]`
- **`present(request: ComponentRequest?)`** (`:459-476`) — the generalized `render_component` path. A
  `nil` request (malformed tool call) or a bad payload **still lands on the canvas** as the mandatory
  fallback; a usable `.note` takes the parity path; anything else hosts via the factory. The agent can
  never crash or wedge the UI. `[H]`
- Both funnel into `compose(...)` (`:486-534`), which appends a `Surface` and (in the full app) runs
  the `gate`; `choice`/fallback always float (`:512-518`). `[H]`

### 2.3 The fallback guarantee (copy this exactly)

The factory has a **total, mandatory fallback** (`Factory/ComponentFactory.swift:38-49`): unknown id
→ `FallbackComponentVC(.unknownID)`, throwing builder → `FallbackComponentVC(.badPayload)`. `[H]` The
canvas adds a third path: a `Surface.isFallback` (malformed tool call) → `FallbackComponentVC`
directly (`FloatingCanvas.swift:234-237`). `[H]` `FallbackComponentVC` floors its own size so it can
never render an invisible 0×0 card (`FallbackComponentVC.swift:82-89`). This is the invariant that
lets the model select freely — **the worst case is always a small safe "Couldn't show that" pebble.**
`[H]`

---

## 3. The data-flow trace (tool event → card on glass)

End-to-end, citing each hop. (Realtime/factory internals are slices 01/02 — named, not re-extracted.)

```
[slice 01] RealtimeManager emits a PebblesEvent over its nonisolated AsyncStream
   │   (.note(PostItContent)  OR  .component(ComponentRequest))
   ▼
ConversationModel.apply(_:)                         Conversation/ConversationModel.swift:319-351
   ├─ case .note(content):  noteRequest = NoteRequest(content)               :325-326
   └─ case .component(req): renderComponentRequest(req)                      :327-328
   │
   ▼
ConversationModel.renderComponentRequest(_:)        Conversation/ConversationModel.swift:367-382
   ├─ a usable .note → noteRequest = NoteRequest(content)  (parity path)     :369-372
   └─ else → componentSurfaceRouter(request)  (the ROUTER SEAM)             :375-376
   │                                   (nil-safe: build-to-decide if unwired :377-381)
   ▼
StageForeground wires the seams in .onAppear        Stage/StageForeground.swift:81-123
   ├─ convo.componentSurfaceRouter = { store.present(request:) }            :91-93
   ├─ convo.activeRemindersContextProvider = { store.contextBlock() }       :84-87
   └─ .onChange(of: convo.noteRequest) { store.composeNote(content:) }      :142-145
   │
   ▼
SurfaceStore.present(request:) / .composeNote(_:)   Stage/SurfaceStore.swift:449-534
   └─ appends a Surface (state=.floating) → mutates @Observable `surfaces`
   │
   ▼   (iOS 26 observation: the read in updateProperties re-invokes it)
StageViewController.updateProperties()              App/StageViewController.swift:189-217
   ├─ _ = surfaceStore.floatingSurfaces  (registers the dependency)         :203
   └─ floatingCanvas?.sync()                                                :208
   │
   ▼
FloatingCanvasController.sync()                      Stage/FloatingCanvas.swift:154-229
   ├─ diff store.floatingSurfaces vs live `cards` (add / remove)            :155-213
   ├─ makeBody(for:) → ComponentFactory.shared.make(request, context)       :234-249
   │        └─ [slice 02] registry → real body  OR  FallbackComponentVC
   └─ new CardViewController(surfaceID:bodyVC:) ; applyLayout(animated:)     :184-227
   │
   ▼
CardViewController                                   Stage/CardViewController.swift
   ├─ hosts the factory body in a UIGlassEffect host                        :209-236
   ├─ materialize() animates the glass .effect (never alpha)                :354-392
   └─ drag/flick → onBringToFront / onCollect(→ store) ; deinit frees views :153-154, 488-529
```

**Key seam properties:**
- The router is a **closure on the model**, wired by the view (`ConversationModel.swift:105-110`,
  `StageForeground.swift:91-93`). The model never imports the store — clean inversion of control. `[H]`
- `noteRequest` carries a **fresh UUID per request** (`ConversationModel.swift:84-87`) so SwiftUI's
  `.onChange` fires even for identical answer text. `[H]`
- `present(request:)` is also where the live `componentSurfaceRouter` lands, so **both** the
  note-parity path and the generic-component path converge on the **one** store/canvas. `[H]`
- **Audio is never owned by a view/VC.** `CardViewController.deinit` only releases views
  (`CardViewController.swift:23-24, 153-154`); the session is owned by `ConversationModel`/
  `RealtimeManager`. A card deallocating must never tear down a turn. `[H]`

---

## 4. Captions + state (how transcripts and character state reach the foreground)

- **Character state → scene:** `updateProperties()` reads `conversation.state`/`.tone` and calls
  `pebblesScene.apply(state:tone:)` (`StageViewController.swift:193-195`). First-frame correctness is
  seeded non-animated in `viewWillAppear` (`:170-176`). `[H]`
- **Audio level → scene (per-frame):** `pebblesScene.levelProvider = { conversation.currentLevel() }`
  (`StageViewController.swift:228`; `ConversationModel.currentLevel()` `:241`). Off observation. `[H]`
- **Transcripts → captions:** `ConversationModel` publishes `pebblesText`/`userText`
  (`ConversationModel.swift:76-77`), updated from transcript-delta/final events in `apply(_:)`
  (`:333-346`). `StageForeground.characterColumn` renders two `Caption`s reading those
  (`StageForeground.swift:368-374`); `topText` falls back to a soft status string per state
  (`:386-395`). `[H]`
- **`Caption`** is an ephemeral attributed `Text`: 3-line cap, bounded Dynamic Type, fades on change,
  a11y-hidden when empty (`CaptionsView.swift:12-33`). Deliberately **not** a chat log. `[H]`
- **Dormant wake:** the foreground hosts a full-screen `Color.clear` wake-catcher, interactive ONLY
  while `state == .dormant`, at the BACK of the ZStack so other controls win their taps; a tap calls
  `convo.start()` (`StageForeground.swift:50-60, 408-411`). The veil's *visual* dim lives in
  `StageBackground` behind the SKView so the dormant cairn stays bright (`StageBackground.swift:40-46`,
  `ArrivalVeil.swift:1-13`). `[H]`
- **Pebbles reservation:** `StageForeground` reports a 360pt band's `.global` frame up to the VC
  (`StageForeground.swift:360-366`), which pins the scene's rest-anchor + reserves the same band for
  auto-placed cards (`StageViewController.swift:455-467`). **Optional for MVP** (a fixed anchor works). `[M]`

**Minimal version:** `../snippets/composition/06-StageIslands.swift`.

---

## 5. MVP keep-vs-cut + Source map

### 5.1 Keep-vs-cut for every App/* + Stage/* file

| File | Lines | MVP verdict | Why |
|---|---|---|---|
| `App/CompositionRoot.swift` | 91 | **KEEP** (trim to 1 component) | DI root + registry `[H]` |
| `App/StageHost.swift` | 15 | **KEEP** | the SwiftUI→UIKit bridge `[H]` |
| `App/SwiftUIViewController.swift` | 10 | **KEEP** | the one hosting bridge `[H]` |
| `OpenAIRealtimeSampleApp.swift` | 46 | **KEEP** (drop LAB branch) | `@main` `[H]` |
| `App/StageViewController.swift` | 776 | **KEEP CORE (~220)** | sandwich + hitTest + observation; **cut** board/match-move/drag/P9/P10/DEBUG probes `[H]` |
| `Stage/FloatingCanvas.swift` | 531 | **KEEP CORE (~160)** | passthrough + sync + simple layout; **cut** pocket/free-placement/tuck/collect/reservation `[H]` |
| `Stage/CardViewController.swift` | 764 | **KEEP CORE (~230)** | glass host + body + drag + materialize + sizing-cache; **cut** tuck/collect-flick/pocket/shimmer/sparkle/interactive-yield `[H]` |
| `Stage/SurfaceStore.swift` | 1492 | **KEEP CORE (~110)** | Surface + floating list + present/dismiss/bringToFront; **cut** collect/park/pocket/persistence/expiry/agent-tools/DEBUG `[H]` |
| `Stage/StageForeground.swift` | 412 | **KEEP CORE (~70)** | captions + router wiring + dormant wake; **cut** Hub/providers/scenePhase-flush/DEBUG (~150 lines) `[H]` |
| `Stage/StageBackground.swift` | 49 | **KEEP (stub)** | replace mood/frost/veil with a gradient `[H]` |
| `Stage/CaptionsView.swift` | 33 | **KEEP** | ephemeral caption `[H]` |
| `Stage/PostItModel.swift` | 125 | **KEEP `PostItKind`/`PostItContent`** | note value types the surface model uses; **cut** `PostItNote` (legacy migration) `[H]` |
| `Stage/PocketDrawer.swift` | 262 | **PARTIAL** | keep `PocketLayout.placementRect` if you do free placement (v2); **cut** the pocket tab UI `[M]` |
| `Stage/CollectBoard.swift` | 447 | **CUT** | browse collected cards (P6) `[H]` |
| `Stage/FloatCollectMatchMove.swift` | 103 | **CUT** | float⇄collect handoff animation `[H]` |
| `Stage/HubView.swift` | 525 | **CUT** | settings/memory hub sheet `[H]` |
| `Stage/ArrivalVeil.swift` | 154 | **CUT** (v2 nicety) | iris dilation wake animation `[M]` |
| `Stage/ThumbZoneBar.swift` | 147 | **REPLACE (~30)** | bottom controls (mute/rest/hub) → one Rest/Wake control `[M]` |
| `Stage/ConversationHistoryView.swift` | 175 | **CUT** | history list `[H]` |

**Net:** MVP composition+surface spine ≈ **800–900 lines** distilled from ≈4,900 across these files
(plus the Factory + realtime in other slices). The largest cut is `SurfaceStore` (1492→~110). `[H]`

### 5.2 Source map — exact `file:line` for the spine

| What | Where |
|---|---|
| `@main` + `appRoot` | `OpenAIRealtimeSampleApp.swift:10-46` |
| DI singletons | `App/CompositionRoot.swift:14` (store), `OpenAIRealtimeSampleApp.swift:12-13` (model/motion) |
| Component registration (`.note`) | `App/CompositionRoot.swift:20-29` |
| Representable bridge | `App/StageHost.swift:7-15` |
| Hosting bridge | `App/SwiftUIViewController.swift:6-10` |
| **Reversed-priority hitTest** | `App/StageViewController.swift:33-68` |
| Sandwich install | `App/StageViewController.swift:150-168` (+ `240-317`) |
| `updateProperties()` observation bridge | `App/StageViewController.swift:189-217` |
| `configureScene` (levelProvider, isUserInteractionEnabled=false) | `App/StageViewController.swift:221-238` |
| stone-tap routing (`stageWantsTouch`) | `App/StageViewController.swift:319-340` |
| `pin(_:to:)` helper | `App/StageViewController.swift:612-621` |
| `Surface` value type | `Stage/SurfaceStore.swift:88-139` |
| store + `floatingSurfaces` + budget | `Stage/SurfaceStore.swift:200-230` |
| `present` / `composeNote` / `compose` | `Stage/SurfaceStore.swift:449-534` |
| `dismiss` / `bringToFront` | `Stage/SurfaceStore.swift:543-549, 633-639` |
| the `gate` | `Stage/SurfaceStore.swift:433-443` |
| passthrough container | `Stage/FloatingCanvas.swift:30-35` |
| `sync()` (diff + factory body) | `Stage/FloatingCanvas.swift:154-249` |
| card glass host + body | `Stage/CardViewController.swift:209-236` |
| materialize/dematerialize (`.effect`) | `Stage/CardViewController.swift:354-471` |
| **card-sizing landmine** (measure transform-free + cache) | `Stage/CardViewController.swift:116-128, 306-344` |
| `UIGlassEffect` helper | `Stage/CardViewController.swift:476-484` |
| router seam (model side) | `Conversation/ConversationModel.swift:105-110, 367-382` |
| router seam (view wiring) | `Stage/StageForeground.swift:81-123, 142-145` |
| event → model (`apply`) | `Conversation/ConversationModel.swift:319-351` |
| captions | `Stage/StageForeground.swift:353-395`, `Stage/CaptionsView.swift:12-33` |
| dormant wake | `Stage/StageForeground.swift:50-60, 408-411` |

---

## 6. Risks / landmines (carry these into the build)

1. **The greedy-host trap.** If you ever make the cards or foreground a single full-screen SwiftUI
   host WITHOUT the passthrough `hitTest`, it swallows all touches and the character/background become
   untappable. The passthrough (`FloatingCanvas.swift:30-35`) + reversed root `hitTest`
   (`StageViewController.swift:33-68`) are **non-negotiable**. `[H]`
2. **The card-sizing landmine.** A `UIHostingController`'s intrinsic size is corrupted by a *scale
   transform* on an ancestor (measured 224→162 oscillation under the 0.94 held scale). You MUST measure
   transform-free and cache (`CardViewController.swift:116-128, 306-344`). Skipping this gives
   collapsing/jittering cards. `[H]`
3. **Audio rate vs observation.** Don't read the audio level inside `updateProperties()` (or any
   SwiftUI body) — it churns layout ~50×/s. Use the per-frame `levelProvider` pull
   (`StageViewController.swift:228`). `[H]`
4. **Animate `.effect`, never `alpha`,** for the Liquid-Glass card reveal — alpha on glass looks
   wrong; the opaque backing fades separately (`CardViewController.swift:346-392`). `[H]`
5. **A view must never own audio/session** (`CardViewController.swift:23-24`). Keep teardown in the
   model. `[H]`
6. **iOS 26 deployment target.** `UIGlassEffect` + automatic observation tracking
   (`updateProperties()`) are iOS-26 APIs; there's a defensive `UIBlurEffect` fallback
   (`CardViewController.swift:476-484`) but the observation auto-invoke is core. `[M]`
7. **`maxVisibleFloating` overflow.** The full app COLLECTS overflow to a board; if you cut the board
   you must pick a policy (drop-oldest is in the MVP snippet) or cards pile up unbounded
   (`SurfaceStore.swift:206, 439-443`). `[M]`

---

## 7. Open questions (for the orchestrator / other slices)

1. **`ConversationModel` event/property surface** (slice 01): this slice assumes `.state`, `.tone`,
   `.currentLevel()`, `.pebblesText`, `.userText`, `.noteRequest`, `.componentSurfaceRouter`,
   `.start()`. Confirm the realtime-core slice exposes exactly these (or rename in the snippets). `[M]`
2. **Factory surface** (slice 02): snippets call `ComponentFactory.shared.make/register`,
   `ComponentRequest`, `JSONValue`, `FactoryContext(ownsCardChrome:)`, `FallbackComponentVC(reason:)`,
   `NotePayload.toPostItContent()`, `ComponentBuildError.emptyNote`. These should come from slice 02. `[H]`
3. **Keep persistence in v1?** The store's debounced off-main `PersistenceWriter`
   (`SurfaceStore.swift:277-431`) is genuinely nice (cards survive relaunch) but adds an actor + JSON
   schema. Recommend **v2**. `[M]`
4. **SpriteKit vs a simpler character** (slice 03): the sandwich assumes a full-screen `SKView` with
   `apply(state:tone:)` / `levelProvider` / `stoneHit` / `poke`. If slice 03 ships a thinner character,
   the `stageWantsTouch` hit-test predicate needs an equivalent "is this point on the character?". `[M]`

---

## 8. Confidence & verification

- **Method:** full reads of all 4 App/* files, `SurfaceStore.swift` (1492 lines, full),
  `FloatingCanvas.swift`, `CardViewController.swift`, `StageForeground/Background/CaptionsView`,
  `NoteComponent`, `FactoryContext`, `ComponentFactory`, `ComponentID`, `ComponentPayloads`,
  `FallbackComponentVC`, `PostItModel`, `PocketDrawer` (full), plus headers of `CollectBoard`/
  `ArrivalVeil`/`ThumbZoneBar`; targeted reads of `ConversationModel` (the router/event/caption seams).
  Line counts via `wc -l`. `[H]`
- **Not done (out of scope / owed):** did not compile the distilled snippets (they reference slice
  01/02 types by name and are illustrative, not drop-in); did not read `CollectBoard`/`HubView`/
  `ThumbZoneBar`/`ConversationHistoryView` in full (labeled from headers + cross-references) — these
  are all CUT, so low risk. `[M]`
- **Line numbers** are from this HEAD; per the repo's own guidance they can drift — reference by
  symbol/branch when in doubt. `[M]`
