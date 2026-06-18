# AGENTS.md — minimal-realtime-kit

A minimal, **bring-your-own-key** iOS voice agent: realtime voice + tool calling against the latest
OpenAI **GPT Realtime** API, distilled into a clean, **PUBLIC** open-source repo. Voice is OpenAI
Realtime via **AIProxySwift** (direct BYO-key mode) over AVFoundation; the mic is always open. Tools
render agent-driven cards via a data-only factory; an audio-reactive **SpriteKit** character embodies
the agent.

> **Read first, in order:** `SPEC.md` (architecture + invariants N1–N6 + the latest-API truth + decision
> D1) → `PROJECT-PLAN.md` (tiers, task cards T0.1…T5.x, the wave table §3, the verify loop §4). Then the
> `research/01..07` file(s) and `snippets/*` your task card cites. **This repo is PUBLIC — secret hygiene
> is non-negotiable (N1).**

## Canonical project facts (do not drift)

- Project: `MinimalRealtimeKit.xcodeproj` · scheme `MinimalRealtimeKit` · target/product `MinimalRealtimeKit`.
- Bundle id: `com.example.MinimalRealtimeKit` (neutral — **never** a `com.rayfernando.*` id or any Apple Team ID).
- App source dir: `MinimalRealtimeKit/` — a **`PBXFileSystemSynchronizedRootGroup`**: **new files in this folder
  auto-include in the target. NEVER hand-edit the `.pbxproj`.** (Config templates live in `Config/`.)
- Deployment target: **iOS 26.0**. Sim: **iPhone 17 Pro (iOS 26.x)**. An iOS 18 sim cannot install.
- One SPM dependency: **AIProxySwift `0.153.0`** (MIT), product `AIProxy`. No other third-party deps.
- Default actor isolation is **MainActor** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  `SWIFT_APPROACHABLE_CONCURRENCY = YES`, Swift language mode 5.0). The realtime networking layer is the
  `@AIProxyActor` global actor; mark its members `nonisolated` where they cross to the stream.

## Build / Run / Verify

Use the **XcodeBuildMCP** tools (preferred) or `xcodebuild`. **Build Debug AND Release** for every change
(Release proves nothing leaked outside `#if DEBUG`). There is **no test target and no CI** — the
build + sim-screenshot + grep loop below is the only safety net; the live realtime loop **cannot** be
driven headlessly (no live key/backend in QA), so verify the realtime invariants by **code audit**.

```bash
cd /Users/ray/Projects/AIProxyRealtime2Demo/minimal-realtime-kit
# Debug (compile-only) on an iOS 26 sim:
xcodebuild -project MinimalRealtimeKit.xcodeproj -scheme MinimalRealtimeKit \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/mrk_dd build CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/b.log
grep -E 'BUILD SUCCEEDED|BUILD FAILED|error:' /tmp/b.log     # then repeat with -configuration Release

# Boot + install + screenshot (acceptance evidence):
UD=<iPhone-17-Pro-iOS-26-udid>; xcrun simctl boot "$UD" 2>/dev/null; sleep 8
xcrun simctl install "$UD" /tmp/mrk_dd/Build/Products/Debug-iphonesimulator/MinimalRealtimeKit.app
xcrun simctl launch "$UD" com.example.MinimalRealtimeKit
sleep 4; xcrun simctl io "$UD" screenshot /tmp/mrk.png
```

### The three headless gates (run on EVERY change)

1. **Build Debug AND Release** on an iOS 26 sim — both must be `BUILD SUCCEEDED`.
2. **Realtime invariant audit (N2):** `rg -n 'OpenAIRealtimeResponseCreate' MinimalRealtimeKit/` — once
   tool-calling (Tier 2) lands, **expect exactly 4** sites: greeting / choice-pick (`sendUserChoice`) /
   deferred tail (`completeDeferredToolTurn`) / inline tail. Before Tier 2 there is only the greeting site.
   Reference the sites **by symbol/branch, not line number** (lines drift).
3. **Secret scan (N1) — expect 0 real values:**
   `rg -n -i 'sk-[A-Za-z0-9]{20}|ek_[A-Za-z0-9]|Bearer [A-Za-z0-9]|v2\||aiproxy\.com|api\.openai\.com/v1|com\.rayfernando|DEVELOPMENT_TEAM = [A-Z0-9]{10}' .`
   Placeholders (`<<PASTE_YOUR_OWN>>`, empty xcconfig defaults) are fine; **real** keys/URLs/Team-IDs are not.

## Invariants & guardrails (N1–N6 — do not break)

- **N1 — No secret ships, ever.** BYO-key only (user pastes their key → Keychain
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Never commit a key / partial key / service URL / Apple
  Team ID / `com.rayfernando.*` id. **Secret-scan before every commit** (this repo is public).
- **N2 — Exactly ONE `response.create` per tool turn.** A bare `conversation.item.create` (tool output /
  user item / system note) triggers NO response — only `response.create` does. Canonical sites (4 total):
  greeting, `sendUserChoice` (a card tap = a NEW user turn), the shared deferred tail
  (`completeDeferredToolTurn` — the ONE site slow/network tools funnel through), and the inline tail
  (fast/local tools). A `responseInFlight` guard is set **before** every send (pairs with server-VAD
  `createResponse:true`) so a 2nd `response.create` is never issued while one is active. **Build every new
  tool on the inline or deferred tail — never add a 5th raw `response.create`.**
- **N3 — Total mandatory fallback for the factory.** Unknown component id / malformed payload / throwing
  builder / nil tool call → a `FallbackComponentVC` card. The agent can never crash or wedge the UI. The
  model passes **data, never behavior/code** (no HTML, no expressions). Register components in
  `registerComponents()`; the registry is a plain dict (NOT compiler-enforced) so a launch-time
  `assertAllRegistered()` over `ComponentID.allCases` catches a forgotten `register()`.
- **N4 — A view/VC never owns audio or the session.** Audio + session are owned by `RealtimeManager` /
  `ConversationModel`. A card/component/VC deallocating must NEVER tear down audio. No `deinit` touches
  the session.
- **N5 — One event stream, one drainer.** `RealtimeManager` exposes ONE `nonisolated
  AsyncStream<PebblesEvent>`; `ConversationModel` (`@MainActor @Observable`) is the SOLE consumer.
- **N6 — Audio level is read per-frame, OFF observation.** ~50×/s amplitude is pulled in the SpriteKit
  `update` loop via a `levelProvider` closure. Only discrete state/tone go through observation — never the
  level.
- **New files auto-include** (`PBXFileSystemSynchronizedRootGroup`) — never hand-edit the `.pbxproj`.

## DO / DON'T

**DO** — read SPEC + PLAN + your card's cited `research/*` & `snippets/*` first; own only your card's
files; build Debug+Release + screenshot before claiming done; audit the `response.create` count on every
`RealtimeManager` change; keep the tree free of real secrets and `com.rayfernando.*`.

**DON'T** — commit any secret; hand-edit the `.pbxproj`; let a view/VC own audio; add a 2nd
`response.create` to a tool turn; build a tool on the SDK's `.webSearch` case (there is **no** native
realtime web_search — `web_search` is a BYO/stubbed deferred **client** function); copy the source app's
`.xcodeproj`/`.pbxproj` (it carries Team IDs/bundle id).
