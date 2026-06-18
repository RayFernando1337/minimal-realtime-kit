//  PebblesState.swift
//  T1.1 — the discrete states the agent (and, later, the character) can be in.
//
//  `nonisolated` so a value can cross from the @AIProxyActor realtime layer to the
//  @MainActor UI through the event stream without hopping actors (SPEC N5). The state
//  is the "discrete" channel; the continuous audio level is read separately, per-frame,
//  off observation (SPEC N6).

nonisolated enum PebblesState: Equatable, Sendable {
    case dormant      // no live session
    case connecting   // session is starting up
    case idle         // session live, between turns
    case listening    // the user is speaking (energy flows inward)
    case thinking     // a response is forming, before audio arrives
    case searching    // a tool is running (emitted starting in Tier 2)
    case speaking     // the agent is talking (energy flows outward)
}
