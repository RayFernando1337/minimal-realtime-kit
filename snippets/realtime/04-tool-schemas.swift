//
//  04-tool-schemas.swift  —  REDACTED extract for minimal-realtime-kit
//
//  How a function tool is DECLARED to the Realtime API (JSON Schema), plus the decode
//  helpers and a trimmed system-prompt builder.
//
//  Source: OpenAIRealtimeSample/RealtimeManager.swift:1122-1551 (MVP-trimmed).
//  Tools are JSON-Schema objects expressed with the SDK's `AIProxyJSONValue`.
//

import AIProxy

extension RealtimeManager {

    // MARK: - Args (all fields OPTIONAL so a malformed payload decodes, never throws). :991-1038
    struct SearchArguments: Decodable { let query: String }
    struct SurfaceNoteArguments: Decodable {
        let kind: String?
        let title: String?
        let meta: String?
    }

    // MARK: - The tool catalog handed to OpenAIRealtimeSessionConfiguration(tools:). Source: :1137-1432
    static var agentTools: [OpenAIRealtimeSessionConfiguration.Tool] {

        // A no-parameter tool: an empty-object schema. (Pattern from clear_notes, :1300-1304)
        let getTimeSchema: [String: AIProxyJSONValue] = [
            "type": "object",
            "properties": .object([:]),
            "additionalProperties": false
        ]

        // A single required string. (Pattern from web_search, :1176-1186)
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

        // An enum + required/optional strings. (Pattern from surface_note, :1211-1239)
        let surfaceNoteSchema: [String: AIProxyJSONValue] = [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ["place", "reminder", "fact"],
                    "description": .string(
                        "What the card is: 'place' for somewhere to go, 'reminder' for something to "
                        + "do later, 'fact' for a good-to-know takeaway."
                    )
                ],
                "title": [
                    "type": "string",
                    "description": "The ONE big idea, short — headline-style, no trailing period."
                ],
                "meta": [
                    "type": "string",
                    "description": "Optional single supporting line."
                ]
            ],
            "required": ["kind", "title"],
            "additionalProperties": false
        ]

        return [
            .function(.init(
                name: "get_time",
                description: "Return the current time. Use when the user asks what time/day it is.",
                parameters: getTimeSchema
            )),
            .function(.init(
                name: "web_search",
                description: "Look something up on the live web — current news, prices, facts. The "
                    + "MOMENT you call this, say a short line out loud ('Hold on — let me check that.') "
                    + "so they're not sitting in silence. When the result comes back, give the short "
                    + "version in your own voice and name where it came from.",
                parameters: searchSchema
            )),
            .function(.init(
                name: "surface_note",
                description: "Put a single small card on the glass — silently. Use it when one clear "
                    + "takeaway would help them act. Keep it rare and high-signal; never announce it.",
                parameters: surfaceNoteSchema
            ))
        ]
    }

    // MARK: - Decode + JSON helpers. Source: :1122-1133
    static func decodeArguments<T: Decodable>(_ type: T.Type, from arguments: String) -> T? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)   // try? ⇒ malformed → nil → graceful
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    // MARK: - System prompt. Source: :1440-1551 (trimmed to the shape; keep the Tools section honest)
    static func instructions(personality: Personality) -> String {
        """
        \(personality.persona)

        # Tools
        - get_time(): answer time/day questions.
        - surface_note(kind, title, meta?): leave ONE small card on the glass, silently. Rare + high-signal.
        - web_search(query): SPEAK FIRST ("let me check that"), then search. Returns JSON
          { query, results: [ { title, url, snippet } ] } — read the snippets, then answer in YOUR
          voice; never read JSON or URLs aloud. If it's empty/errored, say you couldn't find it.

        # Core
        \(personality.core)
        """
    }
}
