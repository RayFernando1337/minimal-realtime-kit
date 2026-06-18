//  CaptionsView.swift
//  T3.0 — the ephemeral caption (NOT a chat log).
//
//  The agent's words read larger/warmer near the character; the user's words read quieter. Capped
//  at 3 lines with bounded Dynamic Type, it fades on change and is hidden from accessibility when
//  empty. (Distilled from the source app's `CaptionsView`.)

import SwiftUI

struct Caption: View {
    let text: String
    var emphasized: Bool

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(emphasized ? .title3 : .callout)
            .foregroundStyle(emphasized ? .primary : .secondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .opacity(text.isEmpty ? 0 : 1)
            .animation(.easeInOut, value: text)
            .accessibilityHidden(text.isEmpty)
    }
}
