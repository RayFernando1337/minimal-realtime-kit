//
//  CharacterState.swift  (minimal-realtime-kit — REDACTED snippet)
//
//  The CONTRACT side of the character: a discrete activity state (+ an optional tone),
//  plus the one pure function that turns a state into a bag of animation knobs (`CharacterLook`).
//
//  Adapted/reduced from Pebbles:
//    - `OpenAIRealtimeSample/Pebbles/PebblesState.swift`  (state enum, energy, breathPeriod, baseScale)
//    - `OpenAIRealtimeSample/Pebbles/PebblesScene.swift:1321-1414` (StateLook + StateLook.make)
//
//  No secrets here (or anywhere in this slice). Renamed Pebbles* -> Character* and dropped the
//  cairn-only knobs (spread/headDrop/orbit/hop/liftIndex/etc.) — see research/03 for the full list.
//

import CoreGraphics

// MARK: - Inputs

/// INPUT A: what the agent is doing right now. Maps 1:1 from your realtime receiver events.
public enum CharacterState: Equatable, Sendable {
    case dormant      // no live session
    case connecting   // session starting
    case idle         // session live, between turns
    case listening    // user is speaking  (energy flows INWARD)
    case thinking     // a response is forming, before audio
    case searching    // a tool / web_search is running
    case speaking     // the agent is talking (energy flows OUTWARD)

    public enum Energy { case none, inward, outward }

    /// Which way amplitude pushes the body. Only listening/speaking react to voice.
    public var energy: Energy {
        switch self {
        case .listening: .inward
        case .speaking:  .outward
        default:         .none
        }
    }

    /// Seconds per breath cycle; calmer states breathe slower. (PebblesState.swift:43-51)
    public var breathPeriod: Double {
        switch self {
        case .dormant:                 10
        case .connecting, .idle:        6
        case .listening:                4
        case .thinking, .searching:     5
        case .speaking:                 3
        }
    }

    /// Resting scale multiplier per state. (PebblesState.swift:53-62)
    public var baseScale: CGFloat {
        switch self {
        case .dormant:               0.82
        case .connecting:            0.92
        case .idle:                  1.0
        case .listening:             1.03
        case .thinking, .searching:  1.0
        case .speaking:              1.05
        }
    }

    /// Short human status line (handy for a caption / accessibility value). (PebblesState.swift:65-75)
    public var statusLabel: String {
        switch self {
        case .dormant:    "Asleep, tap to wake"
        case .connecting: "Connecting…"
        case .idle:       "Listening for you"
        case .listening:  "Listening"
        case .thinking:   "Thinking…"
        case .searching:  "Looking that up…"
        case .speaking:   "Speaking"
        }
    }
}

/// INPUT (optional): an orthogonal emotional tone that tints the look. Cut entirely for the
/// absolute MVP, or keep just `.playful` for a sustained smile. (PebblesState.swift:80-82)
public enum CharacterTone: Equatable, Sendable {
    case neutral, warm, concerned, playful
}

// MARK: - Look (the per-state animation knobs)

/// The minimal eye geometry the scene knows how to draw.
enum EyeShape { case closed, half, open, wide, up }

/// A flat bag of animation targets the scene eases toward each frame. This is the REDUCED
/// version of `StateLook` — dropped: spread/flattenY→squashY, orbit/counterOrbit, headDrop/
/// headTilt/headRaise/uprightness, liftIndex, hopIndices/happyHop, pulse. (PebblesScene.swift:1321-1346)
struct CharacterLook {
    var scale: CGFloat            // base body scale (from state.baseScale, tone-nudged)
    var squashY: CGFloat          // <1 = flatter/wider resting heap (dormant)
    var rise: CGFloat             // vertical offset (scene points)
    var lean: CGFloat             // listening: tip toward the user
    var alpha: CGFloat            // wake/sleep dim
    var breath: Double            // seconds/cycle; 0 = no breathing (Reduce Motion)
    var energy: CharacterState.Energy
    var eyes: EyeShape
    var bounce: CGFloat           // speaking: extra voice flutter
    var crescentOnPeak: Bool      // speaking: smile on loud amplitude peaks
    var crescentSustained: Bool   // playful: hold the smile regardless of amplitude

    static let idle = CharacterLook(
        scale: 1, squashY: 0.9, rise: 0, lean: 0, alpha: 1, breath: 6,
        energy: .none, eyes: .open, bounce: 0,
        crescentOnPeak: false, crescentSustained: false
    )

    /// The one pure function: state (+ tone) -> pose. Mirrors PebblesScene.swift:1352-1414.
    static func make(state: CharacterState, tone: CharacterTone) -> CharacterLook {
        var l = idle
        l.scale  = state.baseScale
        l.breath = state.breathPeriod
        l.energy = state.energy

        switch state {
        case .dormant:
            l.squashY = 0.5; l.rise = -30; l.alpha = 0.92; l.eyes = .closed
        case .connecting:
            l.rise = -4; l.eyes = .half
        case .idle:
            l.squashY = 0.9; l.eyes = .open
        case .listening:
            l.rise = 10; l.lean = 8; l.eyes = .wide
        case .thinking:
            l.eyes = .up
        case .searching:
            l.rise = 6; l.eyes = .up
        case .speaking:
            l.rise = 14; l.eyes = .open; l.bounce = 1; l.crescentOnPeak = true
        }

        // Tone nudges (optional). (PebblesScene.swift:1399-1413)
        switch tone {
        case .warm:      l.rise += 2
        case .playful:
            l.bounce += 0.6
            if state != .dormant && state != .connecting { l.crescentSustained = true }
        case .concerned: l.scale *= 0.99; if l.eyes == .open { l.eyes = .half }
        case .neutral:   break
        }
        return l
    }
}
