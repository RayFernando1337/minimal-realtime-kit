//
//  ComponentID.swift  (REDACTED / adapted for minimal-realtime-kit)
//  Source: OpenAIRealtimeSample/Factory/ComponentID.swift:19-29
//
//  The versioned catalog of agent-selectable UI components. The model does SELECTION
//  ONLY — it picks an `id` (here) plus a typed payload; the APP owns the registry and a
//  mandatory fallback, so an unknown/unregistered id can never crash or wedge the UI.
//
//  Ids are VERSIONED ("note.v1") so a payload shape can evolve (note.v2) without
//  breaking an agent still emitting the old one.
//
//  `nonisolated` + `Sendable` so the realtime session (an actor) can decode one and ship
//  it across the actor boundary inside an event.
//
//  MVP SUBSET: note (flat/show-only) + choice (interactive) + statCard (structured).
//  Add a case here to introduce a new component; the schema enum is derived from
//  `allCases`, so this is the single source of truth for what the model may select.
//

import Foundation

nonisolated enum ComponentID: String, Codable, CaseIterable, Sendable {
    case note = "note.v1"
    case choice = "choice.v1"
    case statCard = "stat_card.v1"

    // CUT for v1 — each is a self-contained add-back (payload + body + one register line):
    // case list = "list.v1"
    // case lineChart = "line_chart.v1"
    // case donutChart = "donut_chart.v1"
    // case activityRings = "activity_rings.v1"
    // case imageCard = "image_card.v1"
    // case progressSteps = "progress_steps.v1"
}
