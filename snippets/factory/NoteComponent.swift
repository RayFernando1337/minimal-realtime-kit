//
//  NoteComponent.swift  (REDACTED / adapted for minimal-realtime-kit)
//  Source: OpenAIRealtimeSample/Factory/NoteComponent.swift
//    - ComponentBuildError (shared error) ... :50-71  (trimmed to MVP cases here)
//    - NotePayload → content mapping ........ :20-44
//    - NoteComponentView .................... :79-119
//  Builder registration source: OpenAIRealtimeSample/App/CompositionRoot.swift:21-29
//
//  The simplest component: note.v1 = a flat, show-only card. Demonstrates the
//  decode → map → host path and the "lenient mapping; blank → fallback" rule.
//
//  ADAPT: replace the app design tokens (the `.font`, color, padding, frame width, and
//  `.cardChrome()` modifier) with your own. The PATTERN is what matters.
//

import SwiftUI

// MARK: - Shared build error

/// Why a component builder couldn't produce a view. The factory catches this and returns
/// the mandatory `FallbackComponentVC`, so a malformed payload is always a small, safe card.
nonisolated enum ComponentBuildError: Error {
    case emptyNote
    case emptyChoice
    case emptyStatCard
    // Add one case per new component (emptyList, emptyLineChart, …) as you add components.
}

// MARK: - Payload → validated content (single source of the mapping)

extension NotePayload {
    /// Map a (possibly partial) note payload onto a usable note. A headline is REQUIRED
    /// (falling back to `body` so a body-only note still surfaces); an empty `meta` becomes
    /// nil (falling back to `body` when `body` wasn't the headline). Returns nil when there's
    /// no usable text, so a blank card never surfaces — the caller routes to the fallback.
    nonisolated func toNoteContent() -> NoteContent? {
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = trimmedTitle.isEmpty ? trimmedBody : trimmedTitle
        guard !headline.isEmpty else { return nil }

        let trimmedMeta = (meta ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMeta: String?
        if !trimmedMeta.isEmpty {
            resolvedMeta = trimmedMeta
        } else if !trimmedBody.isEmpty, trimmedBody != headline {
            resolvedMeta = trimmedBody
        } else {
            resolvedMeta = nil
        }
        return NoteContent(kind: NoteKind(lenient: kind), title: headline, meta: resolvedMeta)
    }
}

/// The resolved, render-ready note. (In the source app this is `PostItContent`.)
nonisolated struct NoteContent: Sendable {
    let kind: NoteKind
    let title: String
    let meta: String?
}

/// Lenient kind: anything unknown/absent → `.fact`.
nonisolated enum NoteKind: String, Sendable {
    case place, reminder, fact
    init(lenient raw: String?) { self = NoteKind(rawValue: (raw ?? "").lowercased()) ?? .fact }
    var symbol: String { switch self { case .place: "mappin"; case .reminder: "bell"; case .fact: "lightbulb" } }
    var kicker: String { rawValue.uppercased() }
}

// MARK: - Builder

enum NoteComponent {
    @MainActor
    static func make(payload: JSONValue, context: FactoryContext) throws -> UIViewController {
        let note = try payload.decode(NotePayload.self)   // wrong shape throws → fallback
        guard let content = note.toNoteContent() else {   // no usable text → fallback
            throw ComponentBuildError.emptyNote
        }
        return context.host(NoteComponentView(content: content))
    }
}

// MARK: - Hosted body (show-only)

struct NoteComponentView: View {
    let content: NoteContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: content.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(content.kind.kicker)
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(content.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let meta = content.meta, !meta.isEmpty {
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(16)
        .frame(width: 230, alignment: .leading)
        // ADAPT: app card chrome (frosted glass + shadow) goes here.
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(content.kind.kicker). \(content.title)")
        .accessibilityValue(content.meta ?? "")
    }
}
