//  ComponentFactory.swift
//  T4.1 — the registry + front door for agent-driven UI (N3).
//
//  Builders are registered by `ComponentID`; the APP (not the model) owns this map.
//  `make(_:context:)` NEVER throws to the caller: an unregistered id returns a
//  `FallbackComponentVC`, and a builder that throws (malformed payload) is caught and also
//  returns a `FallbackComponentVC`. That total fallback is what makes free agent selection
//  safe — the worst case is always a small, safe card, never a crash or a wedged UI.

import UIKit
import os

/// Builds a `UIViewController` for a component from its opaque payload + the app's typed
/// context. Throwing is the contract: a malformed payload throws, the factory catches it and
/// falls back.
typealias ComponentBuilder = (_ payload: JSONValue, _ context: FactoryContext) throws -> UIViewController

@MainActor final class ComponentFactory {
    static let shared = ComponentFactory()

    private var builders: [ComponentID: ComponentBuilder] = [:]

    /// Register (or replace) the builder for an id. App-owned: the model never touches this.
    ///
    /// FOOTGUN: this is a plain dictionary — it is NOT compiler-enforced. A forgotten
    /// `register()` compiles fine and that id silently routes to the fallback at runtime. See
    /// `assertAllRegistered()` below for a cheap launch-time guard that turns the silent
    /// runtime trap into a DEBUG failure.
    func register(_ id: ComponentID, _ build: @escaping ComponentBuilder) {
        builders[id] = build
    }

    /// Whether an id currently has a registered builder.
    func isRegistered(_ id: ComponentID) -> Bool { builders[id] != nil }

    /// Build the view for a request. NEVER throws: unknown id AND a throwing builder both
    /// return a `FallbackComponentVC`, so the caller can present the result unconditionally.
    func make(_ request: ComponentRequest, context: FactoryContext) -> UIViewController {
        guard let build = builders[request.id] else {
            return FallbackComponentVC(reason: .unknownID(request.id.rawValue))
        }
        do {
            return try build(request.payload, context)
        } catch {
            return FallbackComponentVC(reason: .badPayload(request.id.rawValue, error))
        }
    }

    #if DEBUG
    /// Cheap launch-time guard: assert every `ComponentID` has a registered builder, so a
    /// forgotten `register()` fails loudly in DEBUG instead of silently degrading to the
    /// fallback in production. Call once after `registerComponents()`.
    func assertAllRegistered() {
        for id in ComponentID.allCases {
            precondition(isRegistered(id), "ComponentFactory missing a builder for \(id.rawValue)")
        }
    }
    #endif
}

extension Logger {
    /// Shared log for the factory: registry decisions + every fallback. Neutral subsystem id
    /// (NOT a real bundle id) so the public repo ships no identifying value.
    nonisolated static let componentFactory = Logger(
        subsystem: "com.example.realtimekit",
        category: "ComponentFactory"
    )
}

#if DEBUG
extension ComponentFactory {
    /// Fallback-coverage proof: exercise `make(...)` for a VALID and a MALFORMED request of
    /// each MVP component. The valid ones must return a real hosted body; the malformed ones
    /// must return a `FallbackComponentVC`. Prints a greppable marker AND logs it, so both the
    /// fallback path and every registration are provable headlessly (console capture is flaky
    /// on the sim). Inert unless a caller invokes it (see `CompositionRoot`'s probe hook).
    static func runDemoComponentsProbe() {
        let context = FactoryContext()

        let valid = ComponentRequest(id: .note, payload: .object([
            "title": .string("Bakery on 4th"),
            "meta": .string("7 min walk"),
            "kind": .string("place"),
        ]))
        // Wrong shape for the note builder (a string, not an object) → builder throws → fallback.
        let malformed = ComponentRequest(id: .note, payload: .string("not an object"))
        let statCard = ComponentRequest(id: .statCard, payload: .object([
            "eyebrow": .string("THIS WEEK"),
            "metric": .string("$1,240"),
            "modules": .array([
                .object(["label": .string("Flights"), "value": .string("$820")]),
            ]),
        ]))
        // Registered, but the required `metric` is absent → decode/validate fails → fallback.
        let statCardMalformed = ComponentRequest(id: .statCard, payload: .object([
            "title": .string("No hero number"),
        ]))
        let choice = ComponentRequest(id: .choice, payload: .object([
            "prompt": .string("Which one?"),
            "options": .array([
                .object(["id": .string("a"), "label": .string("This one")]),
                .object(["id": .string("b"), "label": .string("That one")]),
            ]),
        ]))

        let markers = """
        DEMO_COMPONENTS_BEGIN
        note.v1=\(type(of: shared.make(valid, context: context)))
        note.v1(malformed)=\(type(of: shared.make(malformed, context: context)))
        stat_card.v1=\(type(of: shared.make(statCard, context: context)))
        stat_card.v1(malformed)=\(type(of: shared.make(statCardMalformed, context: context)))
        choice.v1=\(type(of: shared.make(choice, context: context)))
        DEMO_COMPONENTS_END
        """
        print(markers)
        Logger.componentFactory.log("\(markers, privacy: .public)")
    }
}
#endif
