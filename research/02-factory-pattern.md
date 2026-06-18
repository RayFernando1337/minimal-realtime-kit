# 02 — The Agent-Driven Component "Factory" Pattern

> Worker slice for the minimal-realtime-kit extraction. Source app: Pebbles
> (`OpenAIRealtimeSample/`). This document distills the **golden** parts of the
> component factory so a new BYO-key repo can render agent-selected UI safely.
>
> **Every claim is cited `file:line` and tagged confidence (high/med/low).** All
> line numbers are HEAD as read this session; re-grep symbols, not numbers, since
> they drift. No secrets exist in these files (no keys/URLs); example payloads and
> the `Logger` subsystem id are genericized in the snippets.

Companion snippets: `minimal-realtime-kit/snippets/factory/` (REDACTED / adapted).

---

## 0. TL;DR

The model never ships code or behavior. It does **selection only**: it picks a
**versioned string id** (`"note.v1"`) and fills a **typed JSON payload** (data). The
**app** owns a registry that maps id → a builder closure that decodes the payload into
its own typed struct, validates it, and returns a hosted `UIViewController` card. A
**total, mandatory fallback** guarantees the worst case is always a small safe card —
never a crash, never a wedged UI:

- unknown / unregistered id → `FallbackComponentVC(.unknownID)`
- payload the builder can't decode/validate (builder throws) → `FallbackComponentVC(.badPayload)`
- malformed / undecodable tool call (nil request) → `FallbackComponentVC(.malformedToolCall)`

Because that safety net is total, the agent can be given *free* selection over the
catalog. (`ComponentFactory.swift:5-9, 38-49`, conf high)

---

## 1. The pattern: registry → id → typed payload → builder → host → card

### 1.1 Data flow (end to end)

```
model tool call: render_component { id:"choice.v1", payload:{…}, render_hint? }
        │
        ▼
RealtimeManager."render_component" case
   decodeArguments(ComponentRequest.self, from: event.arguments)   # lenient JSON decode
        │  ok → emit(.component(request))      nil → emit(.component(nil))
        ▼  (rides a nonisolated AsyncStream<PebblesEvent> across the actor boundary)
ConversationModel.apply(.component) → renderComponentRequest(request)
        │  (note shortcut → existing note path; else →)
        ▼
componentSurfaceRouter → SurfaceStore.present(request:)   # the on-canvas owner
        │
        ▼
FloatingCanvas.makeBody(for: surface)
   ComponentFactory.shared.make(request, context: FactoryContext(onUserChoice:…))
        │  builders[id]?  ── nil ─────────────▶ FallbackComponentVC(.unknownID)
        │  try build(payload, context)  ── throws ─▶ FallbackComponentVC(.badPayload)
        ▼  ok
   builder: payload.decode(XPayload).validated() → context.host(XComponentView)
        ▼
   UIViewController (UIHostingController) → presented as a floating card
```

Citations:
- Tool-call dispatch decodes `ComponentRequest` and emits the event:
  `RealtimeManager.swift:712-730` (the `"render_component"` case), `:718`
  (`decodeArguments(ComponentRequest.self,…)`), `:1122-1125` (`decodeArguments` is
  just `try? JSONDecoder().decode`), `:142` (`emit`). (conf high)
- The event type that carries the request across the actor boundary:
  `PebblesState.swift:86-105`, specifically `case component(ComponentRequest?)` at
  `:100`. The enum is `nonisolated … Sendable`. (conf high)
- Drain + route on the `@MainActor` model: `ConversationModel.swift:319-351`
  (`apply`), `:327-328` (`.component` → `renderComponentRequest`), `:366-382`
  (`renderComponentRequest`: note-parity shortcut, then `componentSurfaceRouter`,
  then a build-to-decide fallback if the router isn't wired yet). (conf high)
- The router seam to the canvas store: `ConversationModel.swift:105-110`
  (`componentSurfaceRouter`), `SurfaceStore.swift:463-482` (`present(request:)` /
  `composeFallback`). (conf high)
- The live build site with a *real* context: `FloatingCanvas.swift:234-249`
  (`makeBody` builds a `FactoryContext` whose `onUserChoice` is keyed to this
  surface, `ownsCardChrome:false`, then calls `ComponentFactory.shared.make`). (conf high)

### 1.2 The five moving parts

1. **The id enum** — `ComponentID: String, Codable, CaseIterable, Sendable`, one case
   per component, raw value **versioned** (`note = "note.v1"`). `nonisolated` so the
   realtime actor can decode one and ship it inside an event. (`ComponentID.swift:19-29`, conf high)

2. **The request + opaque payload** — `ComponentRequest { id; payload: JSONValue;
   renderHint? }`. Decoding is deliberately lenient: a missing/unknown `id` **throws**
   (→ fallback), an absent `payload` becomes `.object([:])`, a garbled `render_hint`
   is dropped. `JSONValue` is a minimal fully-`Codable` JSON enum whose `decode<T>()`
   re-encodes itself and decodes into the builder's own typed struct — a shape mismatch
   throws there. (`ComponentPayloads.swift:205-240` request, `:242-297` JSONValue +
   `decode<T>` at `:293-296`, conf high)

3. **The registry + front door** — `ComponentFactory` holds `[ComponentID:
   ComponentBuilder]`. `ComponentBuilder = (JSONValue, FactoryContext) throws ->
   UIViewController`. `make(_:context:)` **never throws to the caller**: missing builder
   → fallback; builder throws → caught → fallback. (`ComponentFactory.swift:22`
   typealias, `:24-50` the class, `:40-49` the two-branch fallback, conf high)

4. **The typed context (behavior lives here, not in the model)** — `FactoryContext`
   hands builders **typed closures** (`onUserChoice: (String) -> Void`), flags
   (`reduceMotion`, `ownsCardChrome`), and the single hosting helper `host(_:)`. This
   is *the* mechanism for "model passes data, app owns behavior": an interactive card
   calls `context.onUserChoice(optionID)` — the model never ships a callback.
   (`FactoryContext.swift:18-49`, `host()` at `:43-48`, conf high)

5. **The mandatory fallback** — `FallbackComponentVC` logs *why* on init (telemetry) and
   renders a tiny "Couldn't show that" card pinned to its root view so it can never
   collapse to 0×0. `Reason` is `unknownID | badPayload(_, Error) | malformedToolCall`.
   (`FallbackComponentVC.swift:17-101`, `Reason` at `:20-24`, conf high)

### 1.3 Each builder is a 3-line contract

Every component is the same triple (mirrored across all 9): a `validated()` on the
payload, a `make(payload:context:)` builder, and a SwiftUI body. The builder body is
always **decode → validate → host**:

```startLine:65:OpenAIRealtimeSample/Factory/ListComponent.swift
    static func make(payload: JSONValue, context: FactoryContext) throws -> UIViewController {
        // Wrong-shaped payload (e.g. missing `items`) throws here → factory falls back.
        let raw = try payload.decode(ListPayload.self)
        // Decoded but unusable (no non-empty item) → throw so the factory falls back.
        guard let list = raw.validated() else { throw ComponentBuildError.emptyList }

        return context.host(ListComponentView(payload: list))
    }
```

`context.host(body)` is the ONE place a SwiftUI body becomes a hosted card — it wraps
the body in a `UIHostingController`, sets `backgroundColor = .clear` and
`sizingOptions = [.intrinsicContentSize]`, and threads `ownsCardChrome`. Centralizing
it means a new component is one line and can't get hosting wrong.
(`FactoryContext.swift:43-48`; bridge `SwiftUIViewController.swift:6-10`, conf high)

### 1.4 "Data, never behavior/code; version the ids"

- **Data, never code.** The payload is pure JSON (`JSONValue` has no function/expr
  case — only null/bool/number/string/array/object). The model can't send HTML, code,
  or an expression. A URL (in `image_card`) is treated as *data* — handed to
  `AsyncImage`, never executed, and only after http(s) validation.
  (`ComponentPayloads.swift:248-297`; `ImageCardComponent.swift:79-87` http(s)
  validation, conf high)
- **Behavior via typed closures.** The one interactive component, `choice`, gets its
  behavior from `FactoryContext.onUserChoice` — the app maps the chosen option **id**
  (data) back to an action. (`ChoiceComponent.swift:56-66`, `FactoryContext.swift:19-21`, conf high)
- **Version the ids.** Raw values carry `.v1`. A payload shape can evolve to `note.v2`
  with a new case + builder while an agent still emitting `note.v1` keeps working
  (old id stays registered). (`ComponentID.swift:5-8, 19-29`, conf high)

---

## 2. The registration footgun ("register in N places") + schema derivation

Adding a component touches **several seams**. Some are compiler-enforced, some are not —
and the dangerous one is the *non-enforced* one.

### 2.1 The seams (with the real enforcement status)

| Seam | File | Enforced? | If you forget |
|---|---|---|---|
| 1. `ComponentID` case | `ComponentID.swift:19-29` | n/a (the trigger) | nothing exists yet |
| 2. Payload struct | `ComponentPayloads.swift` | no | builder won't compile (good) |
| 3. Builder registration | `CompositionRoot.registerComponents()` `:20-90` | **NO (runtime)** | **silently routes to fallback** |
| 4. Collect-board body | `CollectedComponentBody.collectedBody(for:)` `:42-113` | **YES (exhaustive switch, no `default:`)** | **build fails** |
| 5. Schema prose (descriptor) | `ComponentCatalog` `ComponentID.descriptor` `:39-109` | **YES (exhaustive switch)** | **build fails** |
| 6. Schema order array | `ComponentCatalog.presentation` `:115-117` | no (DEBUG `assertComplete()` `:145-150`) | dropped from advertised schema |

> ⚠️ **Doc-vs-code correction (conf high, code-verified).** The task brief and the repo's
> own `AGENTS.md` DO/DON'T section say *"`ComponentFactory` is compiler-enforced; the
> board seam has a `default:` that silently degrades."* **That is stale.** At HEAD it is
> the **reverse**: the collect-board switch is now exhaustive (no `default:`) and *is*
> compiler-enforced (commit `a506204`, noted in `AGENTS.md` "Docs vs HEAD" and in
> `CollectedComponentBody.swift:33-37`), while the **factory registration is the
> dictionary that is NOT compiler-enforced** — a forgotten `register()` compiles clean
> and just routes that id to the mandatory fallback at runtime (safe, but invisible
> until you notice cards are blank). This is the genuine footgun.
> (`ComponentFactory.swift:24-50` is a plain `[ComponentID: ComponentBuilder]` dict;
> `CollectedComponentBody.swift:42-113` is an exhaustive switch.)

So the real friction is: **the safety net hides the mistake.** A forgotten builder
doesn't crash or fail to build — it quietly degrades to "Couldn't show that," which is
exactly the behavior you want for a *malicious/garbled* model call but is a silent trap
for a *developer* who simply forgot seam #3.

### 2.2 The schema is derived from the registry (single source of truth)

The `render_component` tool schema's allowed `id` set is generated from
`ComponentID.allCases`, and all three prose blocks (tool description, id-selection
guidance, payload field guidance) are assembled from `ComponentCatalog`. The schema can
never drift from the enum, and adding a component's prose is one descriptor.

```startLine:1314:OpenAIRealtimeSample/RealtimeManager.swift
                "id": [
                    "type": "string",
                    // SINGLE SOURCE OF TRUTH: the allowed ids are derived from `ComponentID.allCases`
                    "enum": .array(ComponentID.allCases.map { .string($0.rawValue) }),
                    "description": .string(ComponentCatalog.renderComponentIDDescription())
                ],
```

Citations: `RealtimeManager.swift:1311-1336` (schema), `:1321` (enum from
`allCases`), `:1426-1430` (the `render_component` function tool, description from
catalog); `ComponentCatalog.swift:29-37` (`ComponentDescriptor`), `:39-109` (per-id
`descriptor`, exhaustive), `:119-139` (the three assembled strings). (conf high)

### 2.3 The cleanest minimal version (collapse 6 seams → 2-and-a-half)

For a fresh repo without a collect board, you can cut the friction dramatically:

- **Keep the `ComponentID` enum** as the trigger (seam 1) — it's free safety.
- **Fold the schema prose INTO the builder registration** so adding a component is
  one place. Instead of a separate `ComponentCatalog`, give `register()` an extra
  `descriptor:` argument (or register a small struct `{ builder, schemaProse }`). Then
  the JSON-schema `enum` + descriptions are generated by walking the *registered*
  builders, so registration is the single source of truth and a forgotten builder is
  also a missing schema entry (the model simply can't select it). This removes seams
  5 and 6 and makes seam 3 self-documenting.
- **Drop the collect-board seam (seam 4) for v1** — there's no board in an MVP, so the
  exhaustive second switch disappears. (Re-add it later if you build a "collected" view.)
- **Optionally make seam 3 compiler-enforced** by iterating `ComponentID.allCases` at
  startup and `assert`-ing every case has a registered builder (a DEBUG `precondition`,
  exactly like the existing `ComponentCatalog.assertComplete()` at
  `ComponentCatalog.swift:145-150`). Cheap, turns the silent runtime trap into a
  launch-time failure. (conf high — this is a recommendation, not lifted code)

Net: **id case + payload struct + body/builder + one `register(descriptor:)` call.**

---

## 3. MVP subset recommendation

**Keep 3: `note`, `choice`, `statCard`. Cut 6: `list`, `lineChart`, `donutChart`,
`activityRings`, `imageCard`, `progressSteps`.**

### 3.1 Why these three

They span the whole design space of the pattern with minimum code and zero extra deps:

- **`note`** — the "hello world": a flat, lenient, **show-only** card. Demonstrates the
  decode→map→host path and the "lenient mapping, blank → fallback" rule with the least
  surface. (`NoteComponent.swift:20-44` mapping, `:79-119` view; payload
  `ComponentPayloads.swift:22-28`) (conf high)
- **`choice`** — the **only interactive** component; demonstrates the crux of the whole
  pattern: *behavior via `FactoryContext` typed closure*, not via model-shipped code,
  and the realtime-delicate "first tap is local + instant, the pick is a NEW user turn"
  flow. Without `choice` you can't show "data, never behavior." (`ChoiceComponent.swift:27-50`
  validate, `:56-66` builder wiring `onUserChoice`, `:175-183` local-first tap; new-user-turn
  bridge `ConversationModel.swift:384-390`) (conf high)
- **`statCard`** — show-only but with a **structured/nested payload** (`chip`, a
  `modules` array of tiles) + real `validated()` discipline (require `metric`, trim,
  drop half-empty tiles, cap at 4) + a lenient `tone` → color map. Demonstrates rich
  typed decode and validation beyond a flat note. (`StatCardComponent.swift:28-73`
  validate, `:79-89` builder, `:99-256` view; payload `ComponentPayloads.swift:53-76`) (conf high)

Coverage: flat/lenient (note) · interactive/callback (choice) · structured/validated
(statCard). That's the complete pattern.

### 3.2 What to cut for v1 (and why each is easy to add back)

Each cut is **self-contained** — a payload struct + a body + one `register()` line (+ a
board case/descriptor if you keep those seams). Nothing else depends on them.

| Cut | Why cut for v1 | Add-back cost |
|---|---|---|
| `list` | Show-only string array; redundant once `statCard` shows the pattern. | Trivial (`ListComponent.swift`, ~155 ln) |
| `lineChart` | Needs `import Charts` (Swift Charts) + a VoiceOver-leak workaround in cells. | Small + dep (`LineChartComponent.swift:28`) |
| `donutChart` | Same `import Charts` dep + `#RRGGBB` parsing + a11y workaround. | Small + dep (`DonutChartComponent.swift:29`) |
| `activityRings` | ~287 ln of hand-rolled concentric-ring geometry; view-heavy, not pattern-illustrative. | Medium (`ActivityRingsComponent.swift`) |
| `imageCard` | Adds a **network** surface (`AsyncImage`) + URL validation + async failure states. | Small-medium (`ImageCardComponent.swift`) |
| `progressSteps` | ~285 ln hand-rolled stepper geometry (connector halves, dots). | Medium (`ProgressStepsComponent.swift`) |

Note all 6 are SHOW-ONLY (only `choice` is interactive), so none of them exercise a
new part of the *pattern* — they exercise new *rendering*. That's why dropping them
costs nothing conceptually. (conf high — derived from each file's builder being the
same decode→validate→host triple)

> Tip: `imageCard` is worth re-adding early as the canonical "a URL is **data**, never
> code" example (`ImageCardComponent.swift:46-87`). Keep it in the spec even if you
> cut it from v1 code.

---

## 4. "How to add a component" — the minimal recipe

For the cleaned-up MVP (no collect board; schema folded into registration):

1. **Add the id** (versioned): a case in `ComponentID`
   (`case poll = "poll.v1"`). (model `ComponentID.swift:19-29`)
2. **Add the payload struct** in `ComponentPayloads.swift`: `Codable, Sendable`, all
   fields lenient/optional where possible, plus a `nonisolated func validated() ->
   Self?` that trims/bounds and returns `nil` when there's nothing usable.
   (model `StatCardPayload` + `validated()` `ComponentPayloads.swift:53-76` /
   `StatCardComponent.swift:28-73`)
3. **Add the body + builder**: a SwiftUI `View` and an
   `enum PollComponent { @MainActor static func make(payload:context:) throws ->
   UIViewController { let raw = try payload.decode(PollPayload.self); guard let p =
   raw.validated() else { throw ComponentBuildError.emptyPoll }; return
   context.host(PollComponentView(payload: p)) } }`. (model `ListComponent.swift:63-73`)
   Add a `case emptyPoll` to `ComponentBuildError` (`NoteComponent.swift:50-71`).
4. **Register it** (one line, with its schema prose):
   `ComponentFactory.shared.register(.poll, descriptor: …) { payload, ctx in try
   PollComponent.make(payload: payload, context: ctx) }`. (model
   `CompositionRoot.swift:33-35`)

In the *current* app you'd ALSO add: a `case .poll` to
`CollectedComponentBody.collectedBody` (`:42-113`, compiler will force this) and a
`descriptor` case to `ComponentCatalog` (`:39-109`, compiler will force this), and list
`.poll` in `ComponentCatalog.presentation` (`:115-117`, DEBUG `assertComplete` catches
this). (conf high)

---

## 5. Source map — exact ranges to lift / adapt

> Lift the **core infra** nearly verbatim (it's design-token-free). **Adapt** the
> component bodies (they reference app design tokens: `Palette`, `AppFont`, `Space`,
> `Radius`, `pebbleCardChrome()`, `Motion`). **Re-implement** the realtime wiring against
> your own tool layer.

### Core infrastructure (lift verbatim)
| Concept | Source | conf |
|---|---|---|
| Versioned id enum | `OpenAIRealtimeSample/Factory/ComponentID.swift:19-29` | high |
| Request + opaque JSON + `decode<T>` | `Factory/ComponentPayloads.swift:205-297` (request `:212-240`, `JSONValue` `:248-297`, `decode<T>` `:293-296`) | high |
| MVP payload structs | `Factory/ComponentPayloads.swift:22-28` (note), `:35-44` (choice), `:53-76` (statCard); `RenderHint` `:199-203` | high |
| Registry + total fallback `make()` | `Factory/ComponentFactory.swift:22` (typealias), `:24-50` (class), `:40-49` (fallback branches), `:52-58` (Logger) | high |
| DEBUG fallback-coverage probe | `Factory/ComponentFactory.swift:60-232` | med |
| Typed context + `host()` | `Factory/FactoryContext.swift:18-49`, `host()` `:43-48` | high |
| Mandatory fallback VC + `Reason` | `Factory/FallbackComponentVC.swift:17-101`, `Reason` `:20-24` | high |
| Host bridge | `App/SwiftUIViewController.swift:6-10` | high |

### MVP components (adapt)
| Component | Source | conf |
|---|---|---|
| `ComponentBuildError` (all cases) | `Factory/NoteComponent.swift:50-71` | high |
| note: map + view | `Factory/NoteComponent.swift:20-44`, `:79-119` | high |
| choice: validate + builder + interactive view | `Factory/ChoiceComponent.swift:27-50`, `:56-66`, `:75-184` (local-first tap `:175-183`) | high |
| statCard: validate + builder + view | `Factory/StatCardComponent.swift:28-73`, `:79-89`, `:99-256` | high |

### Registration + schema derivation
| Concept | Source | conf |
|---|---|---|
| `registerComponents()` (all 9 + DEBUG assert) | `App/CompositionRoot.swift:20-90` (the `.note` inline builder `:21-29`) | high |
| Catalog: descriptor + assembled schema strings | `Factory/ComponentCatalog.swift:29-37`, `:39-109`, `:111-152` (`assertComplete` `:145-150`) | high |
| Collect-board seam (exhaustive switch) | `Factory/CollectedComponentBody.swift:42-113`, footgun note `:33-37`, fallback chip `:186-193` | high |

### Realtime wiring (re-implement against your tool layer)
| Concept | Source | conf |
|---|---|---|
| `render_component` JSON schema | `RealtimeManager.swift:1311-1336` (enum from `allCases` `:1321`) | high |
| `render_component` function tool | `RealtimeManager.swift:1426-1430` | high |
| Tool-call dispatch → decode → emit | `RealtimeManager.swift:712-730` (`:718` decode, `:1122-1125` helper, `:142` emit) | high |
| Event type across actor boundary | `Pebbles/PebblesState.swift:86-105` (`case component(ComponentRequest?)` `:100`) | high |
| Drain + route on MainActor | `Conversation/ConversationModel.swift:319-351`, `:366-382`, router `:105-110`, pick→new-turn `:384-390` | high |
| On-canvas store contract | `Stage/SurfaceStore.swift:88-138` (`Surface.componentID`/`payload`), `:463-482` (`present`) | high |
| Live build site (real context) | `Stage/FloatingCanvas.swift:234-249` | high |
| Collected board route | `Stage/CollectBoard.swift:381-392` | high |

---

## Risks / landmines (for the build that follows)

1. **Silent registration trap.** A forgotten `register()` compiles, doesn't crash, and
   degrades to the fallback — invisible. Add a launch-time `assert` over
   `ComponentID.allCases` to surface it. (`ComponentFactory.swift:24-50`, conf high)
2. **Stale docs.** `AGENTS.md` DO/DON'T and the task brief invert the current
   enforcement (factory dict = NOT enforced; board switch = enforced). Trust the code.
   (`CollectedComponentBody.swift:33-37`, conf high)
3. **`choice` is a NEW user turn, not a 2nd response.** The first tap is local/instant
   (no model round-trip); the pick is bridged as a fresh user turn via
   `sendUserChoice`. Wiring it as a second `response.create` on the render turn would
   violate the one-response-per-turn invariant. (`ChoiceComponent.swift:16-21, 175-183`;
   `ConversationModel.swift:384-390`, conf high — see worker slice on the realtime loop)
4. **Two JSON hops.** `JSONValue.decode<T>()` re-encodes then decodes
   (`JSONEncoder`→`JSONDecoder`) per build. Fine at card cadence (rare, one per turn);
   don't call it in a hot loop. (`ComponentPayloads.swift:293-296`, conf med)
5. **`@MainActor` all the way down.** `make`, builders, and `host()` are `@MainActor`
   (they build `UIViewController`s); the payload types are `nonisolated Sendable` so a
   `ComponentRequest` can ride the actor boundary. Keep that split. (`ComponentFactory.swift:24`,
   `FactoryContext.swift:18`, `ComponentPayloads.swift:212`, conf high)
6. **Fallback must never be 0×0.** The fallback VC pins its card to the root view so the
   canvas can measure it; an invisible fallback = a silently-dropped card.
   (`FallbackComponentVC.swift:82-89`, conf high)

## Open questions

- Does the MVP need a "collected/board" view at all? If not, drop seam #4 entirely
  (this doc assumes you can). (conf med)
- Keep `render_hint`? It's carried but barely acted on in the source
  (`ComponentPayloads.swift:194-203`). Recommend dropping for v1. (conf med)
- Where should component schema prose live — a `ComponentCatalog` (current) or folded
  into `register(descriptor:)` (recommended §2.3)? A v1 decision. (conf high it's a real choice)
