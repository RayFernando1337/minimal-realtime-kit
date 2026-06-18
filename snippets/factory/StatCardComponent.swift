//
//  StatCardComponent.swift  (REDACTED / adapted for minimal-realtime-kit)
//  Source: OpenAIRealtimeSample/Factory/StatCardComponent.swift
//    - StatCardPayload.validated() ... :28-73
//    - StatCardComponent.make ........ :79-89
//    - StatCardComponentView ......... :99-256  (tone→color map at :236-243)
//
//  Show-only, but with a STRUCTURED / NESTED payload (a `chip` + a `modules` array of
//  tiles) + real validation discipline (require `metric`, trim everything, drop
//  half-empty tiles, cap at 4) + a lenient `tone` → color map. Demonstrates rich typed
//  decode beyond a flat note. NON-interactive, so it reads nothing from `FactoryContext`.
//
//  ADAPT: replace the app design tokens with your own.
//

import SwiftUI

// MARK: - Payload → validated content

extension StatCardPayload {
    /// The ONE hard requirement is a non-empty `metric` (the hero number) — without it
    /// there's nothing to show, so this returns nil and the builder throws → the fallback.
    /// Everything else is lenient: trims all text, drops any module tile missing a label
    /// OR value, caps tiles at 4, collapses empty strings / a text-less chip to nil.
    nonisolated func validated() -> StatCardPayload? {
        let trimmedMetric = metric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMetric.isEmpty else { return nil }

        let trimmedEyebrow = (eyebrow ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var cleanedChip: Chip?
        if let chip {
            let text = chip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let tone = (chip.tone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                cleanedChip = Chip(text: text, tone: tone.isEmpty ? nil : tone)
            }
        }

        var cleanedModules: [Module] = []
        for module in modules {
            let label = module.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = module.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !value.isEmpty else { continue }
            let id = (module.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cleanedModules.append(Module(id: id.isEmpty ? nil : id, label: label, value: value))
            if cleanedModules.count == 4 { break }
        }

        return StatCardPayload(
            eyebrow: trimmedEyebrow.isEmpty ? nil : trimmedEyebrow,
            metric: trimmedMetric,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            body: trimmedBody.isEmpty ? nil : trimmedBody,
            chip: cleanedChip,
            modules: cleanedModules
        )
    }
}

// MARK: - Builder

enum StatCardComponent {
    @MainActor
    static func make(payload: JSONValue, context: FactoryContext) throws -> UIViewController {
        let raw = try payload.decode(StatCardPayload.self)        // wrong shape → fallback
        guard let stat = raw.validated() else {                   // no metric → fallback
            throw ComponentBuildError.emptyStatCard
        }
        return context.host(StatCardComponentView(payload: stat))
    }
}

// MARK: - Hosted body (show-only)

struct StatCardComponentView: View {
    let payload: StatCardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            heroBlock
            if !payload.modules.isEmpty { moduleRow }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(16)
        .frame(width: 272, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var header: some View {
        if payload.eyebrow != nil || payload.chip != nil {
            HStack(alignment: .center, spacing: 6) {
                if let eyebrow = payload.eyebrow {
                    Text(eyebrow).font(.caption.weight(.semibold)).tracking(0.8)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let chip = payload.chip {
                    Text(chip.text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(toneColor(chip.tone))
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .background(Capsule().fill(toneColor(chip.tone).opacity(0.14)))
                }
            }
        }
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(payload.metric)
                .font(.largeTitle.weight(.bold))   // the ONE hero number earns the display weight
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.5)
            if let title = payload.title {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2)
            }
            if let body = payload.body {
                Text(body).font(.footnote).foregroundStyle(.secondary).lineLimit(3).padding(.top, 2)
            }
        }
    }

    private var moduleRow: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(payload.modules.enumerated()), id: \.offset) { _, module in
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.label).font(.caption2).tracking(0.4)
                        .foregroundStyle(.tertiary).lineLimit(1)
                    Text(module.value).font(.headline).foregroundStyle(.primary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.thinMaterial))
            }
        }
        .padding(.top, 2)
    }

    /// Map a lenient `tone` hint to a color. Anything unknown/absent reads as the accent,
    /// so a garbled tone never breaks the skin.
    private func toneColor(_ tone: String?) -> Color {
        switch tone?.lowercased() {
        case "positive", "success", "good", "up": return .green
        case "negative", "danger", "bad", "down": return .red
        case "warning", "caution", "warn":         return .orange
        default:                                    return .accentColor
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let eyebrow = payload.eyebrow { parts.append(eyebrow) }
        parts.append(payload.metric)
        if let title = payload.title { parts.append(title) }
        if let chip = payload.chip { parts.append(chip.text) }
        if let body = payload.body { parts.append(body) }
        for module in payload.modules { parts.append("\(module.label): \(module.value)") }
        return parts.joined(separator: ". ")
    }
}
