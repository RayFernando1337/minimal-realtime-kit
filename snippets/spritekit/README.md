# snippets/spritekit — minimal procedural character

A tiny, **pure-SpriteKit** creature that listens, speaks, and reacts — driven by a discrete
state + a continuous audio amplitude. Distilled from Pebbles' `PebblesScene.swift` (1416 lines)
down to **one orb + two eyes**. No assets, no fonts, no third-party deps, **no AIProxy, no keys.**

See `../../research/03-spritekit-character.md` for the full extraction, the MVP-vs-stretch split,
and exact `file:line` provenance for every behavior.

## Files

| File | What it is | Adapted from |
|---|---|---|
| `CharacterState.swift` | The contract: `CharacterState` (7 cases) + `CharacterTone` + `CharacterLook.make` (state→pose pure function). | `PebblesState.swift` + `PebblesScene.swift:1321-1414` |
| `MinimalCharacterScene.swift` | The scene: per-frame `update` reads `levelProvider`, eases the orb's pose, blinks, smiles on voice peaks. | `PebblesScene.swift` (reduced) |
| `AudioLevelMeter.swift` | Lock-guarded RMS meter; `level()` read once/frame. Make two (mic + TTS). | `Engine/AudioLevelMeter.swift` (near-verbatim) |
| `CharacterView.swift` | ~40-line SwiftUI `SpriteView` host. | `PebblesView.swift` |

## The contract (two inputs, one output)

- **Input A — discrete state** → call `scene.apply(state:tone:)` when it changes (via SwiftUI `onChange` / observation).
- **Input B — continuous amplitude 0…1** → `scene.levelProvider = { meter.level() }`, read every frame **inside the scene**.
- **Output** → procedural motion (scale in/out, breath, blink, posture, smile).

```
state/tone ──(discrete, observation)──▶ scene.apply(state:tone:) ──▶ CharacterLook (pose targets)
   mic/TTS ──▶ AudioLevelMeter ──(closure, per frame)──▶ scene.update() ──▶ eased orb + eyes
```

## ⚠️ The one rule that matters (performance)

**Amplitude is PULLED once per frame, never PUSHED through SwiftUI/observation.**
A 60 Hz level signal routed through `@State`/`@Observable`/`updateProperties` invalidates the view
graph every frame → layout thrash, jank, battery drain. So:

- `state` / `tone`  → SwiftUI `onChange` (discrete, a few times per turn). ✅
- `level`           → a `() -> Float` closure the scene reads in `update(_:)`. ✅

(Source: `PebblesScene.swift:26,380`; `StageViewController.swift:227-228` — *"sampled per-frame in
the scene (kept OFF observation/layout)."*)

## Drop-in (4 steps)

```swift
// 1. Two meters; pick which to read by whose turn it is.
let micMeter = AudioLevelMeter()      // feed from AVAudioEngine mic tap: micMeter.ingest(buffer:)
let ttsMeter = AudioLevelMeter()      // feed from realtime audio deltas: ttsMeter.ingestPCM16(base64:)

func currentLevel() -> Float {
    switch state {                    // your app's current CharacterState
    case .listening: return micMeter.level()
    case .speaking:  return ttsMeter.level()
    default:         return 0
    }
}

// 2. Host it (SwiftUI). The closure is read per-frame; state is pushed on change.
CharacterView(state: state, tone: tone, level: currentLevel)

// 3. (UIKit alternative) present the scene yourself:
let scene = MinimalCharacterScene(size: view.bounds.size)
scene.levelProvider = { [weak self] in self?.currentLevel() ?? 0 }
let skView = SKView(); skView.allowsTransparency = true; skView.isOpaque = false
skView.presentScene(scene)
scene.apply(state: state, tone: tone)   // call again whenever state/tone changes
```

4. Wire your realtime receiver events → `CharacterState` (`listening` when the user speaks,
   `thinking` before audio, `speaking` while the agent talks, `searching` during a tool call, etc.).

## Assets / fonts

**None.** Every texture is drawn at runtime with Core Graphics (`makeBodyTexture` /
`makeShadowTexture` / `makeEyeTexture`). No sprite sheets, no atlases, no bundled fonts.

## What was intentionally cut (add back as "stretch")

9-stone cairn · per-stone springs · physics poke→tumble · drag/stack · the Pixar happy-hop +
pebble toss · react-to-elements glance + anticipatory look-up · dormant "z z z" · ground cast
shadow · searching orbit dance. These are *delight*, not legibility — the orb+eyes already reads
"listening / thinking / speaking." Re-introduce them from `PebblesScene.swift` (line ranges in
research/03 §5) once the core ships.
