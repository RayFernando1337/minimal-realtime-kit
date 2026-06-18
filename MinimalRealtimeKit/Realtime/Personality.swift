//  Personality.swift
//  T1.2 — the voice agent's identity: how it refers to itself, which OpenAI realtime
//  voice it speaks in, and the system prompt spliced into the session configuration.
//
//  `nonisolated` + `Sendable` so the @AIProxyActor manager can hold one and use the
//  `static let default` from its `nonisolated init` (the project's default isolation is
//  MainActor, so this type opts out explicitly).

nonisolated struct Personality: Equatable, Sendable {
    /// How the agent refers to itself in conversation.
    let name: String
    /// An OpenAI built-in realtime voice, e.g. "marin" or "cedar". The voice locks after
    /// the first audio of a session.
    let voiceName: String
    /// The system prompt sent as the session's `instructions`.
    let instructions: String

    init(name: String, voiceName: String = "marin", instructions: String) {
        self.name = name
        self.voiceName = voiceName
        self.instructions = instructions
    }

    /// A friendly, minimal default voice agent.
    static let `default` = Personality(
        name: "Pebbles",
        voiceName: "marin",
        instructions: """
        You are Pebbles, a warm and friendly voice companion.
        Keep your replies short and natural — usually a sentence or two — the way people \
        talk out loud, not the way they write.
        Be calm, genuinely helpful, and easy to interrupt: if the person starts talking, \
        stop and listen.
        When the conversation begins, open with a brief, welcoming hello.
        """
    )
}
