//  CompositionRoot.swift
//  T3.0 — the app's single DI / composition root.
//
//  In the full app this owns the process-lifetime singletons (the surface store) and the
//  agent-driven component registry. For v1 the registry is EMPTY: there is no factory / card
//  surface yet (those land in a later "agent-driven cards" card, Tier 4). The app entry still
//  calls `registerComponents()` once at launch so the call site is in place and the later card is
//  a one-file fill — no churn to App.swift.

import Foundation

/// One composition root (an `enum`, so it can never be instantiated). It is the single place the
/// app registers agent-driven components.
enum CompositionRoot {

    /// Register the app's component builders. **Intentionally empty for v1.** A later card (Tier 4 —
    /// the data-only component factory) fills this with `ComponentFactory.shared.register(...)` calls
    /// (plus a launch-time `assertAllRegistered()`); until then there is no card surface to populate,
    /// so leaving this empty keeps the composition spine + character shippable on their own.
    @MainActor static func registerComponents() {
        // No-op for now. (Tier 4 fills this in.)
    }
}
