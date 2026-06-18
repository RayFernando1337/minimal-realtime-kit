# 05 — Config, Secrets, Build Settings, Dependencies & Project Structure

> Worker E slice. Goal: (a) guarantee **no key leaks** into the new open-source repo, and
> (b) give a builder everything needed to make a fresh Xcode project **compile + run**.
> Every real value is redacted to `"<<REDACTED>>"`. Citations are `file:line`; confidence tagged.
> Source app root: `/Users/ray/Projects/AIProxyRealtime2Demo/`.

---

## 1. Secrets to strip (DEFINITIVE list)

There are **exactly 4 hardcoded secret VALUES** in the tracked source — all in one file. A builder
must guarantee none reach the new repo. (Verified two ways: narrow grep `partialKey|serviceURL|aiproxy.com`
and literal-signature grep `= "v2\||sk-|Bearer [A-Za-z0-9]|unprotectedAPIKey` — both resolve to the
same 4 lines.)

| # | Location | What it is | Value | Confidence |
|---|----------|-----------|-------|------------|
| 1 | `OpenAIRealtimeSample/RealtimeManager.swift:182` | OpenAI **AIProxy partial key** (`v2\|…` format) | `"<<REDACTED>>"` | high |
| 2 | `OpenAIRealtimeSample/RealtimeManager.swift:183` | OpenAI **AIProxy service URL** (`https://api.aiproxy.com/…`) | `"<<REDACTED>>"` | high |
| 3 | `OpenAIRealtimeSample/RealtimeManager.swift:862` | Exa **AIProxy partial key** (web_search leg) | `"<<REDACTED>>"` | high |
| 4 | `OpenAIRealtimeSample/RealtimeManager.swift:863` | Exa **AIProxy service URL** (web_search leg) | `"<<REDACTED>>"` | high |

These are consumed at `RealtimeManager.swift:189-192` (`AIProxy.openAIService(partialKey:serviceURL:)`)
and `RealtimeManager.swift:889-896` (`AIProxy.request(partialKey:serviceURL:…)`). The new repo replaces
both with `Secrets`-resolved values (see §2 + `snippets/config/SecretsReader.swift.example`). (high)

### Personal identifiers to scrub (not secrets, but don't ship Ray's account info)

| Location | What | Value | Action | Confidence |
|----------|------|-------|--------|------------|
| `project.pbxproj:182,246` | Apple Team ID (project-level Debug/Release) | `"<<REDACTED:TEAM_ID_A>>"` | blank `DEVELOPMENT_TEAM` | high |
| `project.pbxproj:276,309` | Apple Team ID (target-level Debug/Release) | `"<<REDACTED:TEAM_ID_B>>"` | blank `DEVELOPMENT_TEAM` | high |
| `project.pbxproj:290,323` | Bundle identifier | `com.rayfernando.OpenAIRealtimeSample` | rename to a neutral id | high |

> Note the **two different Team IDs** (project vs. target) — both must be cleared. A fresh Xcode
> project sets these from the building developer's own account, so a builder just leaves them empty. (high)

### NOT secrets (runtime-resolved / gitignored) — document, don't panic

- **OpenClaw base URL + token** are **never hardcoded**. They resolve at runtime via an
  env → launch-arg → gitignored `*.local.swift` chain (`OpenClaw/OpenClawConfig.swift:68-103`;
  stopgap `OpenClaw/OpenClawDevConfig.swift:42-94`). The token var is only used as
  `Bearer \(token)` at `OpenClaw/OpenClawBrain.swift:131`. No value in tracked source. (high)
- **AIProxy DeviceCheck bypass** (simulator-only): base file declares an empty default
  (`Config/DeviceCheck.xcconfig:14`) and `#include?`s a **gitignored** local override
  (`Config/DeviceCheck.xcconfig:16`, ignored at `.gitignore:9`). The real token lives in
  `Config/DeviceCheck.local.xcconfig`, which **does not exist in the checkout** (verified: glob
  `Config/*.local.xcconfig` → 0 files). The `.example` only has the placeholder
  `paste-your-simulator-bypass-token-here` (`Config/DeviceCheck.local.xcconfig.example:8`). (high)
- **`*.local.swift`** files: none present (glob → 0 files); gitignored at `.gitignore:14`. (high)
- **Doc prose mention**: `docs/openclaw-memory/06-app-sdk-retargeting-and-hybrid.md:114` mentions the
  string `https://api.aiproxy.com` but it's **prose only — no key**, and `docs/` won't be copied. (high)

**Bottom line for a builder:** start the new repo from a *fresh* Xcode project (do NOT copy the
`.pbxproj`/`.xcodeproj`), copy only the Swift/asset files you want, and the only literal strings to
hunt-and-kill are the 4 in `RealtimeManager.swift`. (high)

---

## 2. Keyless / BYO-key plan (project-structure POV)

The source app already follows the right *shape* — empty defaults + gitignored overrides + a
"paste your value here" gate (`RealtimeManager.swift:181-187` throws `.missingCredentials` if the
placeholder is unreplaced). The new repo formalizes this so **zero keys ship** and a clean clone
**still compiles**. Three viable mechanisms (a builder can ship #1 alone for MVP):

1. **In-app paste-your-key → Keychain** *(recommended for an open-source app)*. A first-run screen
   takes the user's own key, stores it in the Keychain, and the session reads it back. No build-config
   plumbing; nothing on disk in git. (Worker G confirms the SDK-preferred path — ephemeral token vs.
   on-device key.) (med — pattern is standard; exact SDK call is Worker G's)
2. **`Config/Secrets.xcconfig` (gitignored) + `Secrets.xcconfig.example` (committed)** — mirrors the
   app's existing DeviceCheck pattern. Empty defaults so a fresh clone builds; the user copies the
   example and pastes their own values. **Gotcha:** xcconfig values aren't visible to Swift at runtime
   unless surfaced via the generated Info.plist (`INFOPLIST_KEY_<KEY> = $(<KEY>)`), then read with
   `Bundle.main.object(forInfoDictionaryKey:)`. (med — the INFOPLIST_KEY_ mapping should be verified at build time)
3. **Process env for the simulator** (`SIMCTL_CHILD_<KEY>=…`) — dev convenience, never ships. (high)

**Templates delivered** under `minimal-realtime-kit/snippets/config/`:
- `Secrets.xcconfig.example` — placeholder xcconfig (covers both direct-BYOK and AIProxy transports).
- `gitignore.template` — copy to repo root as `.gitignore` (BYO-key hardened).
- `SecretsReader.swift.example` — `enum Secrets` that resolves Keychain → Info.plist → env → nil,
  with a placeholder-rejecting guard. Drop-in replacement for the stripped literals.

---

## 3. Dependencies (SPM)

Source: `OpenAIRealtimeSample.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:1-15`
and `project.pbxproj:113-115, 82-84, 10, 31`.

| Package | Location | Resolved version | Revision | MVP? | Confidence |
|---------|----------|------------------|----------|------|------------|
| **AIProxySwift** (product `AIProxy`) | `https://github.com/lzell/AIProxySwift` | **0.153.0** | `db818f8e4db04893135a32036995486d974beb8d` | **ESSENTIAL** | high |

- **The ONLY SPM dependency.** It provides the realtime transport, the OpenAI realtime session,
  audio PCM base64 helpers, and the generic proxied `request`/`session` used by the Exa tool. (high)
- `README.md:11` notes the project deliberately tracks `0.153.0` (GA), up from the upstream sample's
  pre-GA `0.140.0`. For the new repo, pin a recent version; Worker G validates the current best version
  + whether direct (`AIProxy.openAIDirectService(unprotectedAPIKey:)`, seen commented at
  `RealtimeManager.swift:195`) vs. proxied is preferred. (high)
- Foundation, AVFoundation, SwiftUI, UIKit, os, CoreText are **system frameworks** (no SPM). (high)

---

## 4. Minimal build settings (for a fresh Xcode project)

All from `OpenAIRealtimeSample.xcodeproj/project.pbxproj`. Two config layers: **project-level**
(`:127-267`, Debug `0D41D30E…` / Release `0D41D30F…`) and **target-level** (`:268-334`, Debug
`0D41D311…` / Release `0D41D312…`).

### Must-have

| Setting | Value | Where | Notes | Conf |
|---------|-------|-------|-------|------|
| `IPHONEOS_DEPLOYMENT_TARGET` | **26.1** | `:200,258` | Very high bar — needs an **iOS 26.x simulator** (AGENTS.md gate). New repo MAY lower it; verify the realtime GA APIs still resolve. | high |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | `"To speak with the AI, the app needs permission to use your microphone"` | `:279,312` | **REQUIRED** — mic prompt; app is voice-first. | high |
| `GENERATE_INFOPLIST_FILE` | `YES` | `:278,311` | No physical `Info.plist`; usage keys live as `INFOPLIST_KEY_*`. | high |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.rayfernando.OpenAIRealtimeSample` | `:290,323` | **Rename** (scrub Ray). | high |
| `SWIFT_VERSION` | `5.0` | `:297,330` | Swift *language mode* 5.0… | high |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | **`MainActor`** | `:294,327` | …but **default actor isolation = MainActor** — critical. Drives the `nonisolated` keywords sprinkled across the app (e.g. `OpenClawConfig.swift:19`, `OpenClawDevConfig.swift:48-65`). A builder must match this or those files won't compile as-is. | high |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` | `:293,326` | Pairs with the above (Swift 6 concurrency on a 5.0 mode). | high |
| `TARGETED_DEVICE_FAMILY` | `"1,2"` | `:298,331` | iPhone + iPad. | high |
| `ASSETCATALOG_COMPILER_APPICON_NAME` / `…GLOBAL_ACCENT_COLOR_NAME` | `AppIcon` / `AccentColor` | `:272-273,305-306` | Asset catalog must define these names. | high |

### Nice-to-have / observed

- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` (`:296,329`); `ENABLE_PREVIEWS = YES`
  (`:277,310`); `CODE_SIGN_STYLE = Automatic` (`:274,307`); `ENABLE_USER_SCRIPT_SANDBOXING = YES`
  (`:185,249`); `MARKETING_VERSION = 1.0` (`:289,322`); `objectVersion = 77`,
  `CreatedOnToolsVersion = 26.1.1` (`:6,100`). (high)
- `baseConfigurationReference = DeviceCheck.xcconfig` is wired **only to the target's Debug config**
  (`:270`); the target Release config (`:302-304`) has **no** base config — i.e. the xcconfig is a
  Debug-only convenience. The new repo's `Secrets.xcconfig` should hook in the same way (or via a
  committed base `.xcconfig` that `#include?`s it). (high)

### New-files auto-include (IMPORTANT)

`project.pbxproj:18-24, 78-80` — the app source group is a **`PBXFileSystemSynchronizedRootGroup`**
(`path = OpenAIRealtimeSample`). New files dropped in the folder are **auto-included** in the target;
you **never hand-edit the `.pbxproj`** (AGENTS.md guardrail). A fresh Xcode 16+/26 project gives you
this by default. **Consequence for fonts:** the app registers TTFs **programmatically** via CoreText
(`DesignSystem/FontLoader.swift:25-47`) precisely so it needs no `.pbxproj`/Info.plist `UIAppFonts`
edits (`FontLoader.swift:8-9`). (high)

### Assets / resources

- `Assets.xcassets/`: only **AppIcon** (`AppIcon.appiconset/Contents.json`) + **AccentColor**
  (`AccentColor.colorset/Contents.json`) + root `Contents.json` — no embedded image payloads to
  license. Safe; can ship default/empty. (high)
- Fonts (`OpenAIRealtimeSample/Resources/Fonts/`): **DM Serif Display** (Regular + Italic) and
  **Hanken Grotesk** (variable) — both Google Fonts under the **SIL Open Font License (OFL)**, so
  **safe to redistribute** in an open-source repo *if* the OFL license text ships alongside. Family
  names matter for lookup: `"DM Serif Display"`, `"Hanken Grotesk"` (`FontLoader.swift:18-19`).
  Optional for MVP. (med — OFL is the standard Google Fonts license; confirm the bundled TTFs' license
  files before shipping)
- `Background/Shaders/AbstractScene.metal` — background visual only; **cut for MVP** (Worker C/D
  territory). Metal needs no special build setting beyond the default Metal compile. (high)

### Build/run invariants (from `AGENTS.md` + `README.md`)

- **iOS 26.x simulator REQUIRED** — an iOS 18 sim refuses to install at deployment target 26.1
  (`AGENTS.md` Build/Run; `README.md:17,24`). (high)
- Realtime networking is wrapped by the **`@AIProxyActor`** global actor — `RealtimeManager` is
  `@AIProxyActor final class` (`RealtimeManager.swift:22`), exposing one `nonisolated`
  `AsyncStream<PebblesEvent>` (`:32`). The new repo keeps audio/session ownership in the
  manager/model, never a view. (high)
- No test target / no CI in the source repo; verification is the **simulator screenshot + grep loop**
  (`AGENTS.md`). The minimal repo can keep that or add a tiny smoke test. (high)
- Device runs need no DeviceCheck bypass (Apple DeviceCheck works on-device); only the **simulator**
  needs the bypass token, and only to start a *live* session (`README.md:25,44-46`). (high)

---

## 5. Proposed minimal file/dir tree (NEW repo)

High-level; favors the in-app-paste BYO-key path with the xcconfig route as an optional dev convenience.

```
minimal-realtime-voice/
├── README.md                      # BYO-key setup, iOS-version note, run steps
├── LICENSE                        # repo license (e.g. MIT)
├── THIRD_PARTY/OFL.txt            # ONLY if bundling DM Serif / Hanken fonts
├── .gitignore                     # from snippets/config/gitignore.template
├── Config/
│   ├── Base.xcconfig              # committed; `#include? "Secrets.xcconfig"`; INFOPLIST_KEY_* maps
│   └── Secrets.xcconfig.example   # committed template (real Secrets.xcconfig is gitignored)
├── <App>.xcodeproj/               # FRESH project — do NOT copy the source .pbxproj
└── <App>/                         # PBXFileSystemSynchronizedRootGroup (auto-include)
    ├── App.swift                  # @main; calls AppFonts.registerIfNeeded() if fonts kept
    ├── Secrets.swift              # from SecretsReader.swift.example (Keychain→plist→env→nil)
    ├── RealtimeManager.swift      # @AIProxyActor; keys via Secrets, NOT literals  (Worker A)
    ├── ConversationModel.swift    # @MainActor; sole event-stream drainer          (Worker A)
    ├── Tools/                     # tool-calling definitions + dispatch            (Worker A/B)
    ├── KeyEntryView.swift         # first-run paste-your-key UI (Keychain)
    ├── Assets.xcassets/           # AppIcon + AccentColor (can be default)
    └── Resources/Fonts/           # OPTIONAL: DM Serif Display + Hanken Grotesk (OFL)
```

Cut from MVP (incidental to realtime+tools): the entire `OpenClaw/` subsystem (self-hosted brain),
the Exa web_search AIProxy leg (replace with a trivial example tool), `Background/Shaders/*.metal`,
SpriteKit character, and the card/factory surface (those are other workers' stretch slices).

---

## Sources
- `OpenAIRealtimeSample/RealtimeManager.swift:16-20, 181-195, 856-897` (secret sites + consumers, `@AIProxyActor`)
- `OpenAIRealtimeSample/OpenClaw/OpenClawConfig.swift:10-103`, `OpenClawDevConfig.swift:5-94`, `OpenClawBrain.swift:131` (runtime-resolved, no hardcoded token)
- `Config/DeviceCheck.xcconfig:1-17`, `Config/DeviceCheck.local.xcconfig.example:1-9`, `.gitignore:1-17`
- `OpenAIRealtimeSample.xcodeproj/project.pbxproj:6,10,18-24,78-115,182-334` (build settings, SPM, sync group, team/bundle)
- `…/swiftpm/Package.resolved:1-15` (AIProxySwift 0.153.0)
- `OpenAIRealtimeSample/DesignSystem/FontLoader.swift:8-55`; `Assets.xcassets/**`; `Resources/Fonts/*`; `Background/Shaders/AbstractScene.metal`
- `README.md:1-69`, `AGENTS.md` (Build/Run/Verify + invariants)

## Open questions
- **Deployment target**: keep 26.1 (matches source, gates on iOS 26 sim) or lower it for reach? Depends
  on which realtime GA APIs the chosen AIProxySwift version needs (Worker G / Worker A).
- **INFOPLIST_KEY_ → arbitrary runtime key** mapping for the xcconfig route — works for usage-description
  keys for sure; confirm it surfaces *custom* keys at build time, else prefer the Keychain path. (med)
- **Font shipping**: confirm the bundled DM Serif / Hanken TTFs carry their OFL text before redistributing,
  or cut fonts from MVP.
- **AIProxy vs. direct BYOK vs. ephemeral token** — the default transport for the new repo is Worker G's call;
  this scaffolding supports all three.

## Confidence & verification
- **High** on the strip list (4 secrets), the single SPM dep + version, and the core build settings —
  all read directly from tracked files and cross-checked with two independent greps + glob.
- **Medium** on the xcconfig→runtime `INFOPLIST_KEY_` mapping and the exact font license files (OFL is
  near-certain for these Google families but unverified in-tree).
- Not run: no build performed (read-only slice); no live secret pasted anywhere. Verified absence of
  gitignored secret files on disk via glob (`*.local.swift`, `Config/*.local.xcconfig` → 0).
