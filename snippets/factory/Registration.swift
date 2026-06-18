//
//  Registration.swift  (REDACTED / adapted for minimal-realtime-kit)
//  Combines, in one place, the seams that wire the factory to the realtime tool layer:
//
//   A. registerComponents()    — App/CompositionRoot.swift:20-90
//   B. schema-from-registry    — RealtimeManager.swift:1311-1336 (enum from allCases :1321),
//                                ComponentCatalog.swift:29-152 (descriptor :39-109)
//   C. tool-call dispatch      — RealtimeManager.swift:712-730 (decode :718, helper :1122-1125)
//   D. event → render routing  — PebblesState.swift:100 (event), ConversationModel.swift:319-382
//
//  Sections C/D are PSEUDO-CODE against a generic tool layer — re-implement against your
//  realtime SDK. Sections A/B are close to the source.
//

import Foundation
import UIKit

// MARK: - A. Register the app's component builders (app-owned; the model never touches this)

enum CompositionRoot {
    @MainActor static func registerComponents() {
        // note.v1 — inline builder (the source registers note inline; the rest delegate).
        ComponentFactory.shared.register(.note) { payload, context in
            try NoteComponent.make(payload: payload, context: context)
        }
        // choice.v1 — interactive; the builder wires the body's tap to context.onUserChoice.
        ComponentFactory.shared.register(.choice) { payload, context in
            try ChoiceComponent.make(payload: payload, context: context)
        }
        // stat_card.v1 — show-only structured card.
        ComponentFactory.shared.register(.statCard) { payload, context in
            try StatCardComponent.make(payload: payload, context: context)
        }

        #if DEBUG
        // Turn the silent "forgot to register" trap into a loud launch-time failure.
        ComponentFactory.shared.assertAllRegistered()
        #endif
    }
}

// MARK: - B. Schema derived from the registry (single source of truth)

/// The render_component tool's allowed ids + per-id prose. In the source this is a
/// `ComponentCatalog` with an EXHAUSTIVE `ComponentID.descriptor` switch (compiler-enforced)
/// plus a hand-ordered `presentation` array (DEBUG-guarded). The MINIMAL/recommended version
/// (research §2.3) folds the prose next to the id so there's one source of truth and the
/// JSON-schema enum is generated from `ComponentID.allCases`.
enum ComponentCatalog {
    /// One sentence of selection guidance per id. EXHAUSTIVE switch → a new `ComponentID`
    /// case fails to BUILD until it declares prose here (free compile-time enforcement).
    static func selectionGuidance(_ id: ComponentID) -> String {
        switch id {
        case .note:
            return "'note.v1' = a single small card; one clear takeaway (a place, a reminder, a fact)."
        case .choice:
            return "'choice.v1' = offer 2–4 tappable choices when THE USER should pick one. " +
                   "Do NOT read the options aloud; the tap comes back as their next turn."
        case .statCard:
            return "'stat_card.v1' = a hero metric with a few supporting tiles; never read the raw numbers aloud."
        }
    }

    /// One block of payload field guidance per id (kept short here).
    static func payloadGuidance(_ id: ComponentID) -> String {
        switch id {
        case .note:
            return "note.v1: { title, body?, meta?, kind? } — kind is 'place'|'reminder'|'fact'."
        case .choice:
            return "choice.v1: { prompt, options:[{ id, label, systemImage? }] } — 2–4 options, stable ids."
        case .statCard:
            return "stat_card.v1: { eyebrow?, metric, title?, body?, chip?:{text,tone?}, modules:[{label,value}] }."
        }
    }

    /// The JSON-schema `id` enum — DERIVED FROM allCases, so it can never drift from the registry.
    static var idEnumValues: [String] { ComponentID.allCases.map(\.rawValue) }

    static var idDescription: String {
        (["Which component to render."] + ComponentID.allCases.map(selectionGuidance)).joined(separator: " ")
    }

    static var payloadDescription: String {
        (["The data for the chosen component."] + ComponentID.allCases.map(payloadGuidance)).joined(separator: " ")
    }

    /// The render_component tool's JSON schema (shape only; encode to your SDK's value type).
    /// Mirrors RealtimeManager.swift:1311-1336.
    static var renderComponentSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "id": ["type": "string", "enum": idEnumValues, "description": idDescription],
                "payload": ["type": "object", "description": payloadDescription],
            ],
            "required": ["id", "payload"],
            "additionalProperties": false,
        ]
    }
}

// MARK: - C. Tool-call dispatch (PSEUDO — re-implement against your realtime SDK)
//
// When the model calls the `render_component` tool, decode the arguments leniently and
// emit an event. A nil decode → emit(.component(nil)) so the UI shows the mandatory
// fallback. The app owns the registry + fallback, so this can never crash.
//
//   case "render_component":
//       if let request = decodeArguments(ComponentRequest.self, from: event.arguments) {
//           emit(.component(request))
//           toolOutput = #"{"shown":true}"#
//       } else {
//           emit(.component(nil))   // malformed/undecodable → fallback on the UI side
//           toolOutput = #"{"shown":false}"#
//       }
//
//   static func decodeArguments<T: Decodable>(_ t: T.Type, from s: String) -> T? {
//       guard let data = s.data(using: .utf8) else { return nil }
//       return try? JSONDecoder().decode(t, from: data)
//   }
//
// IMPORTANT: render_component must NOT add its own response.create — it rides the shared
// single-response path of the tool turn. A `choice` tap is a SEPARATE new user turn (see D),
// not a second response on this turn.

// MARK: - D. Event → render routing on the @MainActor model (PSEUDO)
//
//   enum AgentEvent { case component(ComponentRequest?) /* … */ }   // nonisolated Sendable
//
//   @MainActor func render(_ request: ComponentRequest?) {
//       // present(request:) lands the surface and builds its body via:
//       //   ComponentFactory.shared.make(request, context: FactoryContext(
//       //       onUserChoice: { [weak self] optionID in self?.choicePicked(optionID) },
//       //       reduceMotion: UIAccessibility.isReduceMotionEnabled,
//       //       ownsCardChrome: false))
//       // A nil request → present the FallbackComponentVC(reason: .malformedToolCall).
//   }
//
//   // A choice tap → a NEW USER TURN (not a 2nd response on the render turn):
//   func choicePicked(_ optionID: String) {
//       // map optionID (data) → the option's label, send as a fresh user message/turn.
//   }
