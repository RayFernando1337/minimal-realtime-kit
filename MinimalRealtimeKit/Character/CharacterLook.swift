//  CharacterLook.swift
//  T3.1 — the CONTRACT side of the character: turn the app's discrete `PebblesState`
//  into a flat bag of animation knobs (`CharacterLook`) the scene eases toward each frame.
//
//  Adapted/reduced from `snippets/spritekit/CharacterState.swift`, with one deliberate change:
//  v1 has NO tone (SPEC §8 / the realtime core exposes no `.tone`), so the character is driven
//  off `PebblesState` ALONE. The per-state knobs (energy / breath / base scale) are inlined into
//  the one pure `make(state:)` switch — it stays exhaustive over `PebblesState`, so adding a new
//  state is a compile error here until it has a pose.

import CoreGraphics

// MARK: - Energy (which way amplitude pushes the body)

/// Only `listening` (inward) and `speaking` (outward) react to live voice; everything else is still.
enum CharacterEnergy { case none, inward, outward }

// MARK: - Eyes (the minimal geometry the scene knows how to draw)

enum EyeShape { case closed, half, open, wide, up }

// MARK: - Look (the per-state animation targets)

/// A flat bag of animation targets the scene eases toward each frame. The REDUCED `StateLook`:
/// dropped the cairn-only knobs (spread/orbit/headDrop/liftIndex/hop/pulse) and tone entirely.
struct CharacterLook {
    var scale: CGFloat            // base body scale (from the state)
    var squashY: CGFloat          // <1 = flatter/wider resting heap (dormant)
    var rise: CGFloat             // vertical offset (scene points)
    var lean: CGFloat             // listening: tip toward the user
    var alpha: CGFloat            // wake/sleep dim
    var breath: Double            // seconds/cycle; 0 = no breathing (Reduce Motion)
    var energy: CharacterEnergy
    var eyes: EyeShape
    var bounce: CGFloat           // speaking: extra voice flutter
    var crescentOnPeak: Bool      // speaking: smile on loud amplitude peaks

    static let idle = CharacterLook(
        scale: 1, squashY: 0.9, rise: 0, lean: 0, alpha: 1, breath: 6,
        energy: .none, eyes: .open, bounce: 0, crescentOnPeak: false
    )

    /// The one pure function: `PebblesState` -> pose. Values mirror the source character
    /// (PebblesScene `StateLook.make` + PebblesState breath/scale/energy), tone removed.
    static func make(state: PebblesState) -> CharacterLook {
        var l = idle
        switch state {
        case .dormant:
            l.scale = 0.82; l.breath = 10; l.energy = .none
            l.squashY = 0.5; l.rise = -30; l.alpha = 0.92; l.eyes = .closed
        case .connecting:
            l.scale = 0.92; l.breath = 6; l.energy = .none
            l.rise = -4; l.eyes = .half
        case .idle:
            l.scale = 1.0; l.breath = 6; l.energy = .none
            l.squashY = 0.9; l.eyes = .open
        case .listening:
            l.scale = 1.03; l.breath = 4; l.energy = .inward
            l.rise = 10; l.lean = 8; l.eyes = .wide
        case .thinking:
            l.scale = 1.0; l.breath = 5; l.energy = .none
            l.eyes = .up
        case .searching:
            l.scale = 1.0; l.breath = 5; l.energy = .none
            l.rise = 6; l.eyes = .up
        case .speaking:
            l.scale = 1.05; l.breath = 3; l.energy = .outward
            l.rise = 14; l.eyes = .open; l.bounce = 1; l.crescentOnPeak = true
        }
        return l
    }
}
