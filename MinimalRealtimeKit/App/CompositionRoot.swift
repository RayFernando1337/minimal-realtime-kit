//  CompositionRoot.swift
//  T3.0 / T4.1 — the app's single DI / composition root.
//
//  It is the single place the app registers agent-driven components (the data-only factory).
//  The app entry (`App.swift`) calls `registerComponents()` once at launch. The registry is a
//  plain dict and is NOT compiler-enforced, so this also runs a DEBUG `assertAllRegistered()`
//  that turns a forgotten `register()` from a silent runtime fallback into a launch-time trap.
//
//  The card SURFACE (canvas / floating cards) and the `render_component` tool wiring land in
//  T4.3; this card only stands up the registry, so the factory compiles and is provable
//  standalone (every `make()` returns a hosted `UIViewController`).

import Foundation

/// One composition root (an `enum`, so it can never be instantiated). It is the single place
/// the app registers agent-driven components.
enum CompositionRoot {

    /// Register the app's component builders (app-owned; the model never touches this map).
    /// Each `register` maps a versioned `ComponentID` to a builder that decodes → validates →
    /// hosts. The total fallback (N3) lives in `ComponentFactory.make`, so an unregistered id
    /// or a throwing builder degrades to a `FallbackComponentVC` rather than crashing.
    @MainActor static func registerComponents() {
        // note.v1 — flat, show-only.
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

        // Headless fallback-coverage proof: launch with `SIMCTL_CHILD_MRK_FACTORY_PROBE=1`
        // (→ env `MRK_FACTORY_PROBE`) to exercise valid + malformed requests of every MVP
        // component and emit the DEMO_COMPONENTS markers to the unified log. Inert when unset.
        if ProcessInfo.processInfo.environment["MRK_FACTORY_PROBE"] == "1" {
            ComponentFactory.runDemoComponentsProbe()
        }
        #endif
    }
}
