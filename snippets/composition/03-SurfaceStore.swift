//
//  03-SurfaceStore.swift  (DISTILLED MVP — the SMALLEST viable surface model)
//
//  The single source of truth for "what is on the glass." The full Pebbles store is a 1492-line
//  lifecycle state machine (floating/collected/parked/dismissed/expired + persistence + a lazy
//  auto-expiry clock + agent dismiss/collect/park-by-title tools + ~25 DEBUG seeders). This is the
//  MVP core: a list of floating surfaces + present/dismiss/bringToFront.
//
//  Provenance: Stage/SurfaceStore.swift — the value type (88-139), the @Observable store + budget
//  (200-214, 228-230), present(request:) (459-476), compose() (486-534), dismiss (543-549),
//  bringToFront (633-639), the gate concept (439-443).
//
//  CUTS for MVP (all in the original, flagged OPTIONAL):
//    - SurfaceState machine beyond floating: .collected/.parked/.resurfaced (collect board, pocket,
//      geofence/time park) — SurfaceStore.swift:28-43, 653-857.
//    - Persistence (PersistenceWriter, back-compat decode, debounced off-main save) — :277-431.
//    - Lazy auto-expiry clock — :945-986.
//    - Agent dismiss/collect/park-by-title + the session context block — :551-943.
//    - Free placement / edge tuck (NormalizedPoint/DockEdge) — keep as a v2 nicety — :65-119.
//    - The ~25 #if DEBUG seeders — :988-1491 (≈⅓ of the file).
//
//  DEPENDENCIES: ComponentID / ComponentRequest / JSONValue / NotePayload [slice 02].

import SwiftUI

// MARK: - Surface (the value type)

/// One information surface on the glass. A value type; the store owns the live array and is the only
/// thing that mutates it. (Source: SurfaceStore.swift:88-139, trimmed to MVP fields.)
struct Surface: Identifiable {
    let id: UUID
    /// Which factory component renders this surface's body (MVP registers only `.note`).
    let componentID: ComponentID
    /// The opaque payload the factory builder re-decodes into its own typed struct.
    let payload: JSONValue
    /// Explicit paint order → `view.layer.zPosition`; newest/raised is highest.
    var zIndex: Int
    let createdAt: Date
    /// Transient marker for a malformed/undecodable tool call: the canvas renders these as the
    /// mandatory FallbackComponentVC so a bad tool call can never crash or wedge the UI.
    var isFallback: Bool = false

    /// Deterministic ±3° tilt from the id, stable for the surface's life (hand-placed feel).
    var tilt: Double { (Double(id.uuid.0) / 255.0) * 6.0 - 3.0 }
}

// MARK: - Store

/// Owns every live floating surface — the single source of truth the UIKit canvas reads. Views call
/// `present` / `composeNote` / `dismiss` / `bringToFront`; nobody else keeps surface state.
/// `@Observable` so the VC's `updateProperties()` re-runs when `surfaces` changes.
@MainActor
@Observable
final class SurfaceStore {
    /// The visible floating-card budget. In the full app, overflow beyond this quietly COLLECTS to a
    /// board (CUT here). MVP options: drop the oldest, or just let them stack. (Source: :206)
    static let maxVisibleFloating = 6

    /// Every live surface. (MVP: all are floating; the full app filters by lifecycle state.)
    private(set) var surfaces: [Surface] = []

    /// Floating surfaces in STABLE creation order. The canvas reads this; bring-to-front only bumps
    /// `zIndex` (paint order) so cards never reshuffle where they sit. (Source: :228-230)
    var floatingSurfaces: [Surface] { surfaces }

    private var floatingCount: Int { surfaces.count }

    // MARK: Present (the render_component / surface_note entry points)

    /// Surface an agent note (the `surface_note` path). (Source: composeNote :449-457)
    func composeNote(content: PostItContent) {
        compose(componentID: .note,
                payload: Surface.notePayload(kind: content.kind, title: content.title, meta: content.meta))
    }

    /// Present an agent-selected component (the `render_component` path). A nil request (malformed
    /// tool call) or a bad payload still lands ON the canvas as the mandatory fallback, so the agent
    /// can never crash the UI. (Source: present :459-476)
    func present(request: ComponentRequest?) {
        guard let request else { compose(componentID: .note, payload: .object([:]), isFallback: true); return }
        if request.id == .note,
           let content = (try? request.payload.decode(NotePayload.self))?.toPostItContent() {
            composeNote(content: content)
            return
        }
        compose(componentID: request.id, payload: request.payload)
    }

    /// Build a surface and land it floating. (Source: compose :486-534, with the gate reduced to a
    /// simple budget drop — the full app routes overflow to a collect board instead.)
    private func compose(componentID: ComponentID, payload: JSONValue, isFallback: Bool = false) {
        let surface = Surface(id: UUID(), componentID: componentID, payload: payload,
                              zIndex: nextZIndex(), createdAt: Date(), isFallback: isFallback)
        surfaces.append(surface)
        // MVP overflow policy: keep the budget by dropping the oldest. (Full app COLLECTS it instead.)
        if floatingCount > Self.maxVisibleFloating { surfaces.removeFirst() }
    }

    private func nextZIndex() -> Int { (surfaces.map(\.zIndex).max() ?? -1) + 1 }

    // MARK: Mutations driven by the canvas / user

    /// Remove a surface entirely (swipe / dismiss). (Source: dismiss :543-549, minus the removal-
    /// source bookkeeping the full app uses to re-sync the live session.)
    func dismiss(id: UUID) {
        surfaces.removeAll { $0.id == id }
    }

    /// Raise a surface to the top of the paint order on touch-down. (Source: bringToFront :633-639)
    func bringToFront(id: UUID) {
        guard let index = surfaces.firstIndex(where: { $0.id == id }) else { return }
        let maxZ = surfaces.map(\.zIndex).max() ?? surfaces[index].zIndex
        guard surfaces[index].zIndex != maxZ else { return }
        surfaces[index].zIndex = maxZ + 1
    }
}

// MARK: - Note payload helper (kept from the original so the `.note` body renders identically)

extension Surface {
    /// Build the `.note` builder's `{title, kind, meta}` payload. (Source: SurfaceStore.swift:145-152)
    static func notePayload(kind: PostItKind, title: String, meta: String?) -> JSONValue {
        var dict: [String: JSONValue] = ["title": .string(title), "kind": .string(kind.rawValue)]
        if let meta, !meta.isEmpty { dict["meta"] = .string(meta) }
        return .object(dict)
    }
}
