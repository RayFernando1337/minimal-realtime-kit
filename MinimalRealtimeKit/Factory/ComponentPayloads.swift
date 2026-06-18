//  ComponentPayloads.swift
//  T4.1 — the typed contract the agent fills: a `ComponentRequest` (a versioned id + an
//  opaque payload) plus the per-component payload structs.
//
//  Each builder owns its payload type and decodes it from the opaque `JSONValue` itself, so
//  a malformed payload THROWS inside the builder and the factory degrades to the mandatory
//  fallback (N3) — never a crash. The model passes DATA only: `JSONValue` has no
//  function / expression case, so it can never ship HTML, code, or an expression.
//
//  Everything here is `nonisolated` + `Sendable` so a `ComponentRequest` can ride an event
//  from the realtime actor to the `@MainActor` UI.

import Foundation

// MARK: - Per-component payloads (MVP subset)

/// note.v1 — flat, lenient, show-only. A usable headline is required (validation lives in
/// `toNoteContent()`); everything else is optional.
nonisolated struct NotePayload: Codable, Sendable {
    var title: String?
    var body: String?
    var meta: String?
    var kind: String?   // "place" | "reminder" | "fact" — lenient, defaults to fact
}

/// choice.v1 — "AI proposes, user picks". A `prompt` plus 2–4 tappable `options`, each a
/// stable `id` (DATA the app maps back to a user turn), a label, and an optional SF Symbol.
/// `prompt`/`options` are REQUIRED so a missing one throws at decode time.
nonisolated struct ChoicePayload: Codable, Sendable {
    var prompt: String
    var options: [Option]

    nonisolated struct Option: Codable, Sendable, Identifiable {
        var id: String
        var label: String
        var systemImage: String?
    }
}

/// stat_card.v1 — show-only hero card: an `eyebrow` kicker + optional status `chip` → a big
/// hero `metric` (the ONE number) + optional title/body → a row of small `modules`
/// (label/value tiles). `metric` is the only REQUIRED field.
nonisolated struct StatCardPayload: Codable, Sendable {
    var eyebrow: String?
    var metric: String
    var title: String?
    var body: String?
    var chip: Chip?
    var modules: [Module]

    nonisolated struct Chip: Codable, Sendable {
        var text: String
        var tone: String?   // "positive" | "negative" | "warning" | "neutral"
    }

    nonisolated struct Module: Codable, Sendable, Identifiable {
        var id: String?
        var label: String
        var value: String
    }
}

// MARK: - Placement hint (carried, lenient; barely acted on in v1)

nonisolated enum RenderHint: String, Codable, Sendable {
    case floating
    case replaceCurrent
    case inList
}

// MARK: - Request

/// One agent component request: a versioned `id`, an opaque `payload` (each builder owns its
/// typed decode), and an optional `renderHint`. Decoding is deliberately lenient: a missing
/// `id` or an id that isn't a known `ComponentID` THROWS (→ routed to the fallback), an
/// absent `payload` becomes an empty object (the builder then decides), and an
/// unknown/garbled `render_hint` is dropped rather than failing an otherwise-valid request.
nonisolated struct ComponentRequest: Codable, Sendable {
    let id: ComponentID
    let payload: JSONValue
    var renderHint: RenderHint?

    init(id: ComponentID, payload: JSONValue, renderHint: RenderHint? = nil) {
        self.id = id
        self.payload = payload
        self.renderHint = renderHint
    }

    enum CodingKeys: String, CodingKey {
        case id
        case payload
        case renderHint = "render_hint"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required: an unknown id (not a ComponentID case) or a missing id throws so the tool
        // layer treats it as malformed and surfaces the fallback.
        id = try container.decode(ComponentID.self, forKey: .id)
        // Tolerant: an absent payload degrades to an empty object so a builder that needs
        // content throws cleanly (→ fallback) instead of the decode failing here.
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
        // Tolerant: a bad/unknown render_hint must NOT nuke an otherwise-valid request.
        renderHint = (try? container.decodeIfPresent(RenderHint.self, forKey: .renderHint)) ?? nil
    }
}

// MARK: - Opaque JSON payload

/// A minimal, fully-`Codable` JSON value so the request can carry an arbitrary payload object
/// and each builder can re-decode it into ITS OWN typed struct via `decode(_:)`. A shape the
/// target type can't accept throws — the factory catches that and returns the mandatory
/// fallback, so a malformed payload degrades to "couldn't show that," not a crash.
///
/// NOTE: there is NO function / expression case — the model can only ship DATA, never code.
nonisolated enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Re-decode this opaque value into a builder-owned `Decodable` payload. THROWS when the
    /// value's shape can't satisfy `T` (e.g. a string where the builder expects an object),
    /// which the factory turns into a `FallbackComponentVC`.
    ///
    /// NOTE: two JSON hops (encode → decode). Fine at card cadence (one per turn); don't call
    /// in a hot loop.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}
