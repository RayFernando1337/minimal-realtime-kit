//  SurfaceStore.swift
//  T4.3 — the single source of truth for "what is on the glass."
//
//  The full Pebbles store is a 1492-line lifecycle state machine (floating / collected / parked /
//  dismissed / expired + persistence + a lazy auto-expiry clock + agent dismiss/collect/park-by-title
//  tools + ~25 DEBUG seeders). This is the MVP core: a list of FLOATING surfaces plus
//  present / dismiss / bringToFront, with a small visible budget.
//
//  `@Observable` so `StageViewController.updateProperties()` (iOS 26 automatic observation tracking)
//  re-runs and re-syncs the canvas whenever `surfaces` changes. The model never imports this store —
//  it lands here through a router CLOSURE wired by the stage (clean inversion of control).
//
//  N3 (on the glass): a nil request (a malformed / undecodable `render_component` tool call) still
//  lands ON the canvas, as a fallback Surface — so a bad tool call can never crash or wedge the UI.
//  The factory adds two more fallback seams (unknown id, bad payload) at build time.
//
//  v1 cut: the `surface_note` / `PostItContent` parity path is GONE — `note.v1` renders through the
//  factory like any other id.

import SwiftUI

// MARK: - Surface (the value type)

/// One information surface on the glass. A value type; the store owns the live array and is the only
/// thing that mutates it.
nonisolated struct Surface: Identifiable, Sendable {
    let id: UUID
    /// Which factory component renders this surface's body. Ignored when `isFallback` is true (the
    /// canvas renders the mandatory `FallbackComponentVC` directly in that case).
    let componentID: ComponentID
    /// The opaque payload the factory builder re-decodes into its own typed struct.
    let payload: JSONValue
    /// Explicit paint order → `view.layer.zPosition`; the newest / raised surface is highest.
    var zIndex: Int
    let createdAt: Date
    /// Transient marker for a malformed / undecodable tool call: the canvas renders these as the
    /// mandatory `FallbackComponentVC` so a bad tool call can never crash or wedge the UI (N3).
    var isFallback: Bool = false

    /// Deterministic ±3° tilt derived from the id — stable for the surface's life (a hand-placed feel
    /// that never jitters between layout passes).
    var tilt: Double { (Double(id.uuid.0) / 255.0) * 6.0 - 3.0 }
}

// MARK: - Store

/// Owns every live floating surface — the single source of truth the UIKit canvas reads. The stage
/// calls `present` / `dismiss` / `bringToFront`; nobody else keeps surface state.
@MainActor
@Observable
final class SurfaceStore {
    /// The visible floating-card budget. The full app COLLECTS overflow to a board (CUT here); the
    /// MVP policy is simply to drop the oldest so cards never pile up unbounded.
    static let maxVisibleFloating = 6

    /// Every live surface. (MVP: all are floating; the full app filters by lifecycle state.)
    private(set) var surfaces: [Surface] = []

    /// Floating surfaces in STABLE creation order. The canvas reads this; bring-to-front only bumps
    /// `zIndex` (paint order) so cards never reshuffle where they sit.
    var floatingSurfaces: [Surface] { surfaces }

    // MARK: Present (the `render_component` entry point)

    /// Present an agent-selected component (the `render_component` path). A nil request (a malformed /
    /// undecodable tool call) still lands ON the canvas as the mandatory fallback, so the agent can
    /// never crash the UI (N3). Otherwise the request's id + payload compose a floating surface; an
    /// unknown id or a bad payload then degrades to the fallback at BUILD time, in the factory.
    func present(request: ComponentRequest?) {
        guard let request else {
            // `.note` is an inert placeholder — the canvas renders FallbackComponentVC for `isFallback`.
            compose(componentID: .note, payload: .object([:]), isFallback: true)
            return
        }
        compose(componentID: request.id, payload: request.payload)
    }

    /// Build a surface and land it floating. (The full app routes overflow to a collect board; here the
    /// gate is reduced to a simple budget drop.)
    private func compose(componentID: ComponentID, payload: JSONValue, isFallback: Bool = false) {
        let surface = Surface(id: UUID(), componentID: componentID, payload: payload,
                              zIndex: nextZIndex(), createdAt: Date(), isFallback: isFallback)
        surfaces.append(surface)
        if surfaces.count > Self.maxVisibleFloating { surfaces.removeFirst() }
    }

    private func nextZIndex() -> Int { (surfaces.map(\.zIndex).max() ?? -1) + 1 }

    // MARK: Mutations driven by the canvas / user

    /// Remove a surface entirely (swipe-flick / dismiss).
    func dismiss(id: UUID) {
        surfaces.removeAll { $0.id == id }
    }

    /// Raise a surface to the top of the paint order on touch-down / drag.
    func bringToFront(id: UUID) {
        guard let index = surfaces.firstIndex(where: { $0.id == id }) else { return }
        let maxZ = surfaces.map(\.zIndex).max() ?? surfaces[index].zIndex
        guard surfaces[index].zIndex != maxZ else { return }
        surfaces[index].zIndex = maxZ + 1
    }
}
