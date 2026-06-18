//  ToolCatalog.swift
//  T2.1 / T2.2 — the static side of tool calling: the tool catalog handed to the
//  session, the JSON-Schema for each tool, the lenient decode/JSON helpers, the
//  system-prompt composer, and the bring-your-own web-search seam.
//
//  Everything here is PURE (no session/audio state) so it's marked `nonisolated` and
//  lives off the @AIProxyActor — the dispatch side (instance methods that touch the
//  live session + `responseInFlight`) is in `RealtimeManager+Tools.swift`.
//
//  v1 tool set is deliberately tiny — two teachers:
//    • get_time   — fast / local / zero-network → the INLINE branch.
//    • web_search — slow / network → the DEFERRED branch (and BYO/stubbed: ships NO key).
//  (The source app's `surface_note` is CUT for v1; re-add it as an inline tool the same way.)

import AIProxy
import Foundation

// MARK: - web_search provider seam (BYO — ships NO key; never throws)
//
// `web_search` is a CLIENT function, not a hosted/native realtime tool (the SDK's
// `.webSearch` Tool case is a trap — do not use it). Fulfillment is hidden behind this
// seam so the repo runs with zero extra keys and degrades gracefully.
//
// To wire up a real provider (e.g. Exa, Brave, Tavily, or the OpenAI Responses API's
// `web_search`): implement `WebSearchProvider.search(query:)` to call your service and
// return a compact JSON envelope like `{"query": "...", "results": [{"title","url","snippet"}]}`,
// then inject it: `RealtimeManager(webSearch: MyProvider())`. Keep the key in the Keychain
// (SPEC N1) — never hardcode it here. Your `search(query:)` must NEVER throw/crash: on any
// failure return a JSON error envelope the model can read aloud.

/// Fulfills a `web_search` tool call. `Sendable` + `nonisolated` so the realtime actor can
/// `await` it from its own isolation domain (mirrors `RealtimeCredentialProvider`).
nonisolated protocol WebSearchProvider: Sendable {
    /// Returns a JSON string the model reads. MUST NOT throw — encode failures as JSON.
    func search(query: String) async -> String
}

/// The default: no provider wired in. Returns a graceful "unconfigured" envelope so the
/// agent can say it can't search right now — audio keeps flowing, nothing crashes.
nonisolated struct UnconfiguredWebSearchProvider: WebSearchProvider {
    func search(query: String) async -> String {
        RealtimeManager.jsonString([
            "status": "unconfigured",
            "message": "Web search isn't configured in this build. Implement WebSearchProvider "
                + "to add one (e.g. Exa/Brave)."
        ])
    }
}

// MARK: - The static tool catalog + helpers (pure → nonisolated)

extension RealtimeManager {

    // MARK: Argument structs (ALL fields OPTIONAL so a malformed payload decodes to a
    // partial/nil instead of throwing — lenient decode, never a crash).
    nonisolated struct SearchArguments: Decodable, Sendable {
        let query: String?
    }

    // MARK: The catalog handed to `OpenAIRealtimeSessionConfiguration(tools:)`.
    nonisolated static var agentTools: [OpenAIRealtimeSessionConfiguration.Tool] {
        // A no-parameter tool → an empty-object schema.
        let getTimeSchema: [String: AIProxyJSONValue] = [
            "type": "object",
            "properties": .object([:]),
            "additionalProperties": false
        ]

        // A single required string.
        let searchSchema: [String: AIProxyJSONValue] = [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "What to look up on the web, phrased as a clear search query."
                ]
            ],
            "required": ["query"],
            "additionalProperties": false
        ]

        // render_component: the agent draws a small card on the glass. The allowed `id` set is
        // DERIVED from `ComponentID.allCases` (SINGLE SOURCE OF TRUTH — the schema can never drift
        // from what the registry can build). `payload` is an OPEN object each card validates itself;
        // a wrong shape / unknown id degrades to the mandatory fallback (N3), never a crash.
        let renderComponentSchema: [String: AIProxyJSONValue] = [
            "type": "object",
            "properties": [
                "id": [
                    "type": "string",
                    "enum": .array(ComponentID.allCases.map { .string($0.rawValue) }),
                    "description": .string("Which card to render. note.v1 = a short titled note; "
                        + "choice.v1 = a prompt with 2-4 tappable options (use when you want the person "
                        + "to pick — their tap comes back as a new user turn); stat_card.v1 = a hero "
                        + "number with optional supporting tiles.")
                ],
                "payload": [
                    "type": "object",
                    "description": .string("The card's DATA (the shape depends on id). note: {title, "
                        + "body?, meta?, kind?}; choice: {prompt, options:[{id,label,systemImage?}]}; "
                        + "stat_card: {metric, eyebrow?, title?, body?, chip?, modules:[{label,value}]}. "
                        + "Pass DATA only — never code, HTML, or expressions.")
                ],
                "render_hint": [
                    "type": "string",
                    "enum": ["floating", "replaceCurrent", "inList"],
                    "description": "Optional placement hint; usually omit it."
                ]
            ],
            "required": ["id", "payload"],
            "additionalProperties": false
        ]

        return [
            .function(.init(
                name: "get_time",
                description: "Return the current date and time. Use it when the person asks what "
                    + "time or day it is.",
                parameters: getTimeSchema
            )),
            .function(.init(
                name: "web_search",
                description: "Look something up on the live web — current news, prices, facts. The "
                    + "MOMENT you call this, say a short line out loud (\"Hold on — let me check "
                    + "that.\") so they're not sitting in silence. When the result comes back, give "
                    + "the short version in your own voice and name where it came from.",
                parameters: searchSchema
            )),
            .function(.init(
                name: "render_component",
                description: "Draw a small card on the glass to SHOW something — a note, a choice "
                    + "the person can tap, or a stat card. Pick an `id` from the allowed set and fill "
                    + "`payload` with DATA only. Keep speaking; the card supports your words, it "
                    + "doesn't replace them.",
                parameters: renderComponentSchema
            ))
        ]
    }

    // MARK: Decode + JSON helpers (lenient).
    /// `try?` ⇒ a malformed payload becomes `nil` (graceful), never a thrown error.
    nonisolated static func decodeArguments<T: Decodable>(_ type: T.Type, from arguments: String) -> T? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Serialize a tool result to a compact JSON string (falls back to "{}" on failure).
    nonisolated static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    // MARK: System prompt = persona + a "# Tools" section so the model knows what it can call.
    nonisolated static func instructions(personality: Personality) -> String {
        """
        \(personality.instructions)

        # Tools
        - get_time(): answer "what time/day is it?" questions. Returns JSON { "now": <ISO8601> } —
          read it back naturally (e.g. "It's about 4:30 in the afternoon"), never the raw string.
        - web_search(query): the MOMENT you call this, say a short line out loud ("let me check
          that") so they're not in silence. It returns JSON — either
          { "query", "results": [ { "title", "url", "snippet" } ] } or a { "status", "message" }
          envelope. Read the snippets and answer in YOUR voice; never read JSON or URLs aloud. If it
          comes back "unconfigured", empty, or errored, just say you couldn't look it up right now.
        - render_component(id, payload): draw a small card on the glass to SHOW something — a note,
          a tappable choice, or a stat card. Pick an `id` (note.v1 / choice.v1 / stat_card.v1) and
          fill `payload` with DATA only (no code/HTML). Keep talking; the card supports your words.
          Use choice.v1 when you want the person to pick — their tap returns as a new user turn.
        """
    }
}
