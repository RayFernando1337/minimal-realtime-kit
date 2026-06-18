//
//  CharacterView.swift  (minimal-realtime-kit — REDACTED snippet)
//
//  SwiftUI host for the character: a transparent `SpriteView` over your background. It pushes the
//  DISCRETE state/tone into the persistent scene on change, and binds the CONTINUOUS `level` closure
//  once. The scene owns its own 60fps clock, so it keeps breathing/pulsing even when SwiftUI isn't
//  re-rendering.
//
//  Adapted from `OpenAIRealtimeSample/Pebbles/PebblesView.swift`.
//
//  THE RULE: `state`/`tone` flow through SwiftUI onChange (discrete). `level` is a closure read by
//  the scene every frame (continuous) — NEVER a per-frame @State push. (See research/03 §3.)
//

import SwiftUI
import SpriteKit

struct CharacterView: View {
    var state: CharacterState
    var tone: CharacterTone = .neutral
    /// Read once per frame inside the scene's render loop. Point it at your turn-aware meter.
    var level: () -> Float = { 0 }
    var onPoke: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // One long-lived scene (NOT recreated on every SwiftUI re-eval).
    @State private var scene: MinimalCharacterScene = {
        let scene = MinimalCharacterScene(size: CGSize(width: 320, height: 320))
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        return scene
    }()

    var body: some View {
        SpriteView(scene: scene, options: [.allowsTransparency])
            .accessibilityElement()
            .accessibilityLabel("Assistant")
            .accessibilityValue(state.statusLabel)
            .onAppear {
                pushInputs()
                scene.apply(state: state, tone: tone)
                scene.isPaused = (scenePhase != .active)
            }
            .onChange(of: state) { _, newState in
                pushInputs()
                scene.apply(state: newState, tone: tone)
            }
            .onChange(of: tone) { _, newTone in
                pushInputs()
                scene.apply(state: state, tone: newTone)
            }
            .onChange(of: reduceMotion) { _, _ in
                pushInputs()
                scene.apply(state: state, tone: tone)   // re-resolve the pose under the new setting
            }
            .onChange(of: scenePhase) { _, phase in scene.isPaused = (phase != .active) }
    }

    /// Re-bind closures whenever the view re-evaluates, so a fresh `level`/`onPoke` identity from the
    /// parent doesn't go stale on the long-lived scene. (PebblesView.swift:79-86)
    private func pushInputs() {
        scene.levelProvider = level
        scene.onPoke = onPoke
        scene.reduceMotion = reduceMotion
    }
}
