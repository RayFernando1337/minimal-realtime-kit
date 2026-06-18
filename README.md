# minimal-realtime-kit

A minimal, **bring-your-own-key** iOS voice agent — realtime voice + tool calling against OpenAI's
**GPT Realtime** API, with agent-driven cards and an audio-reactive character. It's the smallest thing
that teaches the patterns well, so you can clone it and experiment the day you open it.

**No keys ship in this repo.** You paste your own OpenAI API key on first run; it's stored in the
device Keychain and used directly (see [Bring your own key](#bring-your-own-key)).

## What you get

- **Realtime voice that feels like an agent** — always-open mic, semantic VAD, **barge-in** (talk over
  it and it stops).
- **Tool calling with discipline** — exactly **one `response.create` per tool turn**, and the
  inline-vs-deferred (fast-vs-slow tool) split. Ships with `get_time` (inline) and `web_search`
  (deferred, BYO EXA key — off until you paste one).
- **Agent-driven cards via a data-only factory** — the model picks a versioned id + a typed JSON
  payload (**data, never code**) and the app renders a card, with a **total mandatory fallback** so a
  bad/unknown selection can never crash or wedge the UI.
- **An audio-reactive SpriteKit character** — a procedural orb + eyes that swells when speaking, draws
  in while listening, blinks, and reacts to taps. Amplitude is sampled per-frame, off observation.

## Requirements

- **Xcode 26+** and an **iOS 26 simulator or device** (deployment target is iOS 26.0; an iOS 18 sim
  cannot install it).
- An **OpenAI API key** with Realtime access (yours — nothing is bundled). Get one at
  [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
- One Swift Package dependency, resolved automatically: [AIProxySwift](https://github.com/lzell/AIProxySwift) `0.153.0`.

## Run

1. Open `MinimalRealtimeKit.xcodeproj` in Xcode.
2. Select the `MinimalRealtimeKit` scheme and an iOS 26 simulator (e.g. iPhone 17 Pro).
3. Build & run. On first launch tap **Add OpenAI API Key**, paste your OpenAI key from
   [platform.openai.com/api-keys](https://platform.openai.com/api-keys) (stored in the Keychain and used
   directly against OpenAI), then tap to connect and start talking.

> The mic + live realtime loop need a real key and a microphone, so the conversation can't be exercised
> headlessly. The build + simulator-screenshot + code-audit loop is the project's safety net (there is no
> test target / CI). See `AGENTS.md` for the verification commands.

## Bring your own key

The key never ships and never leaves the device:

- A first-run screen takes your key and stores it in the **Keychain**
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) — never `UserDefaults`, never a file, never logged.
- A `RealtimeCredentialProvider` seam (`PastedKeyProvider`) hands the realtime client a bearer
  credential, so an **ephemeral-token** backend can be added later without touching the client.
- `web_search` ships **no key**: it's a deferred client function behind a `WebSearchProvider` seam that
  defaults to a graceful "not configured" response. Paste your own **EXA key** in-app to enable it (see
  [Optional: fast web search via EXA](#optional-fast-web-search-via-exa)), or implement the seam for
  another provider (Brave/Tavily, the OpenAI Responses API, …).

### Optional: fast web search via EXA

`web_search` is a **deferred client tool** behind a `WebSearchProvider` seam. Out of the box it returns
a graceful "not configured" response, so the kit runs with just your OpenAI key. To turn it on, **bring
your own [EXA](https://exa.ai) key** — no key ships in the repo:

- In-app, open the key screen and paste your EXA key under **Web search (optional)**.
- The key is stored **only in the Keychain** (same as your OpenAI key) — never `UserDefaults`, never a
  file, never logged, and it never ships.
- When set, `ExaWebSearchProvider` reads the key fresh per call and hits
  [`api.exa.ai/search`](https://exa.ai/docs/reference/search) **directly** with `type: "instant"` —
  EXA's sub-200ms mode built for real-time/voice — then hands the model a compact `{title, url, snippet}`
  list to answer from.
- Get a key at [dashboard.exa.ai/api-keys](https://dashboard.exa.ai/api-keys). Remove it anytime with
  **Forget EXA key** and `web_search` drops back to "not configured".

### Optional: route through AIProxy (keep your key off-device)

This is **not** what v1 ships — it's an alternative for when you outgrow the experimentation kit.

- **Why.** By default the app takes the **direct** path: your pasted OpenAI key lives in the device
  Keychain and connects straight to OpenAI. That's fine for a bring-your-own-key kit, but for a widely
  shipped app you may prefer that a standing OpenAI key never touch the device at all.
- **What it is.** AIProxySwift (already the client SDK here) also supports a **proxied / split-key**
  mode: your real OpenAI key stays in your AIProxy dashboard, and the app ships only a **partial key +
  service URL** — neither of which is your OpenAI key.
- **How to switch (one line of code).** Replace the single
  `AIProxy.openAIDirectService(unprotectedAPIKey:)` call in `Realtime/RealtimeManager.swift` with
  `AIProxy.openAIService(partialKey:serviceURL:)`, supplying the partial key + service URL from your
  AIProxy dashboard. For the simulator only, add the DeviceCheck bypass token — **never ship the bypass
  token.**
- **Setup.** Create an AIProxy account, add your OpenAI key there, then follow the
  [AIProxy integration guide](https://www.aiproxy.com/docs/integration-guide.html).
- **Another off-device option.** An **ephemeral-token** backend works too: the
  `RealtimeCredentialProvider` seam already accepts a short-lived bearer credential minted by your own
  server, so the client never sees a standing key.

## Architecture

UIKit owns composition; SwiftUI hosts the leaf "islands"; SpriteKit is the character. A full-screen
SwiftUI host is greedy in hit-testing, so a UIKit root runs **reversed-priority** routing to let taps
reach the character behind it.

```
@main App
 └─ CompositionRoot (DI; registers the component factory; owns the SurfaceStore)
     └─ StageHost (SwiftUI → UIKit)
         └─ StageViewController  (the sandwich + reversed-priority hitTest)
             ├─ StageBackground   (gradient, behind)
             ├─ SKView(CharacterScene)   (the audio-reactive orb)
             ├─ FloatingCanvas    (the agent-driven cards)
             └─ StageForeground   (captions, connect/mute, key entry, dormant wake)
```

- **`Realtime/`** — `RealtimeManager` (`@AIProxyActor`; the session lifecycle, the mic/receiver loops,
  the tool dispatch, and the **4** `response.create` sites) exposes one `nonisolated
  AsyncStream<PebblesEvent>`. `ConversationModel` (`@MainActor @Observable`) is the **sole** drainer and
  the actor↔UI bridge.
- **`Factory/`** — `ComponentID` + `ComponentRequest`/`JSONValue` (data only) → `ComponentFactory` (a
  registry with a total fallback) → the `note` / `choice` / `statCard` bodies.
- **`Stage/`** — `SurfaceStore` (the single source of truth for cards), `FloatingCanvas`,
  `CardViewController` (a Liquid-Glass card).
- **`Keys/`** — `KeychainStore`, `RealtimeCredentialProvider`, the key-entry screen.
- **`Character/`** — `CharacterScene` + the pure `CharacterLook.make(state:)`.

### The invariants (held throughout — see `AGENTS.md`)

1. **No secret ships.** BYO-key only.
2. **Exactly one `response.create` per tool turn** (4 canonical sites: greeting / choice-pick /
   deferred tail / inline tail).
3. **Total mandatory fallback** for the component factory.
4. A view/VC **never** owns audio or the session.
5. **One** event stream, **one** drainer.
6. Audio level is read **per-frame, off observation**.

## Extending

- **Add a tool:** add a JSON schema + a `case` in the dispatch switch — fast → the inline tail, slow →
  a detached task that finishes through the shared deferred tail. Never add a 5th `response.create`.
- **Add a card:** add a `ComponentID` case, a payload struct + a `decode → validate → host` builder, and
  one `register(...)` line. The `render_component` schema's id list is derived from `ComponentID.allCases`,
  so it can't drift from the registry; a launch-time `assertAllRegistered()` catches a forgotten builder.

## Status

Tiers 0–4 are implemented and verified by the headless gates (Debug **and** Release build on an iOS 26
sim; the `response.create` count audit; a repo-wide secret scan; simulator screenshots of each state and
the cards). The **live** voice loop — barge-in, mute-keeps-session, a live tool call, a model-emitted
card — needs a real key + mic and is the owed manual check. `web_search` stays "not configured" until
you paste your own EXA key (the repo ships none); a live EXA query needs that key + the realtime loop.

## License

MIT — see [`LICENSE`](LICENSE). AIProxySwift is MIT.
