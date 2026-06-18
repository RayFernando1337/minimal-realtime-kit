//  StageBackground.swift
//  T3.0 — the back of the sandwich: everything that draws BEHIND the character.
//
//  The full app layers a mood-driven field + frosted glass + arrival veil; v1 is a calm dark
//  gradient with a faint state-tinted glow behind the orb so the scene has some depth. It is
//  NON-INTERACTIVE (the VC also disables hit-testing on its host) and reads only the discrete
//  state (never the per-frame audio level — N6).

import SwiftUI

struct StageBackground: View {
    @Environment(ConversationModel.self) private var convo

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.04)],
                startPoint: .top, endPoint: .bottom
            )
            // A soft, slow glow that tints with the conversation's discrete state.
            RadialGradient(
                colors: [accent.opacity(0.20), .clear],
                center: .init(x: 0.5, y: 0.42), startRadius: 6, endRadius: 460
            )
            .blendMode(.plusLighter)
            .animation(.easeInOut(duration: 0.6), value: convo.state)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The glow color per state (kept subtle; this is ambience, not a status readout).
    private var accent: Color {
        switch convo.state {
        case .dormant:              return Color(white: 0.20)
        case .connecting:           return .gray
        case .idle:                 return .blue
        case .listening:            return .cyan
        case .thinking, .searching: return .indigo
        case .speaking:             return .purple
        }
    }
}

#Preview {
    StageBackground()
        .environment(ConversationModel())
}
