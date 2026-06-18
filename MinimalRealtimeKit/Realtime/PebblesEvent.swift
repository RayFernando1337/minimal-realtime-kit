//  PebblesEvent.swift
//  T1.1 — the single event contract that crosses the actor boundary.
//
//  `RealtimeManager` (@AIProxyActor) yields these onto ONE `nonisolated
//  AsyncStream<PebblesEvent>`; a single @MainActor model drains them (SPEC N5).
//  `Sendable` is what lets a value travel through the stream between actors.

nonisolated enum PebblesEvent: Sendable {
    /// Discrete lifecycle state for the UI/character.
    case state(PebblesState)
    /// Incremental transcript of what the user said (display only).
    case userTranscriptDelta(String)
    /// The finalized transcript of the user's turn.
    case userTranscriptFinal(String)
    /// Incremental transcript of what the agent is saying.
    case pebblesTranscriptDelta(String)
    /// The finalized transcript of the agent's turn.
    case pebblesTranscriptFinal(String)
    /// The session hit an error; the consumer should go dormant.
    case error(String)
    /// A `render_component` tool call: a model-selected card to put on the glass. A `nil` request is
    /// a malformed / undecodable tool call — the drainer still routes it so the canvas can show the
    /// mandatory fallback (N3). `ComponentRequest` is `Sendable`, so it rides the stream unchanged.
    case component(ComponentRequest?)

    // Intentionally cut for v1: `.tone`, `.note`, `.memoryChanged`.
}
