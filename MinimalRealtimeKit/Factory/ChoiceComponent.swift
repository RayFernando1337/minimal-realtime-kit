//  ChoiceComponent.swift
//  T4.2 — choice.v1: THE interactive component, and the clearest proof of "model passes
//  DATA, app owns BEHAVIOR" (N3).
//
//  The builder wires the view's `onPick` to `FactoryContext.onUserChoice`; the model never
//  ships a callback, only the option ids (data).
//
//  TURN-FLOW (realtime-delicate): the FIRST tap is LOCAL and INSTANT — the view marks the
//  chosen option, disables further taps, and calls `onPick(option.id)`. It does NOT wait on
//  the model and shows no spinner. The pick travels app-side and is later sent as a NEW USER
//  TURN by Tier 4's wiring — NOT a second response on the render_component turn (that would
//  break N2's one-response-per-turn invariant). That bridge is out of scope here.

import SwiftUI

// MARK: - Payload → validated content

extension ChoicePayload {
    /// Validate + clean: a non-empty prompt and at least one option with a usable id + label.
    /// Trims, drops blank/duplicate-id options, caps at 4. Returns nil when there's nothing
    /// usable so the builder throws → the mandatory fallback.
    nonisolated func validated() -> ChoicePayload? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        var seenIDs = Set<String>()
        var cleaned: [Option] = []
        for option in options {
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !label.isEmpty, seenIDs.insert(id).inserted else { continue }
            let symbol = option.systemImage?.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.append(Option(id: id, label: label,
                                  systemImage: (symbol?.isEmpty ?? true) ? nil : symbol))
            if cleaned.count == 4 { break }   // bound the card to a tappable 2–4
        }
        guard !cleaned.isEmpty else { return nil }
        return ChoicePayload(prompt: trimmedPrompt, options: cleaned)
    }
}

// MARK: - Builder

enum ChoiceComponent {
    @MainActor
    static func make(payload: JSONValue, context: FactoryContext) throws -> UIViewController {
        let raw = try payload.decode(ChoicePayload.self)               // wrong shape → fallback
        guard let choice = raw.validated() else {                      // unusable → fallback
            throw ComponentBuildError.emptyChoice
        }
        // The crux: behavior comes from the typed context closure, not from the model.
        return context.host(ChoiceComponentView(payload: choice, onPick: context.onUserChoice))
    }
}

// MARK: - Hosted body (interactive: first tap is LOCAL)

struct ChoiceComponentView: View {
    let payload: ChoicePayload
    /// Invoked with the chosen option's id on the first tap. The builder wires this to
    /// `FactoryContext.onUserChoice`.
    let onPick: (String) -> Void

    /// The locally-chosen option id. Set instantly on first tap (no model round-trip).
    @State private var pickedID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(payload.prompt)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(payload.options) { option in
                    optionButton(option)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(16)
        .frame(width: 248, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choice. \(payload.prompt)")
    }

    @ViewBuilder
    private func optionButton(_ option: ChoicePayload.Option) -> some View {
        let isPicked = pickedID == option.id
        let isDimmed = pickedID != nil && !isPicked
        Button {
            pick(option)
        } label: {
            HStack(spacing: 6) {
                if let symbol = option.systemImage {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                }
                Text(option.label).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isPicked { Image(systemName: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)) }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isPicked ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial))
            }
        }
        .buttonStyle(.plain)
        .disabled(pickedID != nil)
        .opacity(isDimmed ? 0.45 : 1)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    }

    /// First tap wins: mark the option locally (instant — no model wait, no spinner), then
    /// hand the chosen id to the app via `onPick`. Subsequent taps no-op.
    private func pick(_ option: ChoicePayload.Option) {
        guard pickedID == nil else { return }
        if reduceMotion {
            pickedID = option.id
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pickedID = option.id }
        }
        onPick(option.id)
    }
}
