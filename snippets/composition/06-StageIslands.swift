//
//  06-StageIslands.swift  (DISTILLED MVP — illustrative, not copied verbatim)
//
//  The two SwiftUI "leaf" islands the UIKit stage hosts, plus the ephemeral caption. This is where
//  the tool→surface ROUTER is wired and where transcripts/captions + dormant-wake reach the screen.
//
//  Provenance:
//    - Stage/StageForeground.swift  — router wiring in .onAppear (81-123), the noteRequest→surface
//      bridge (142-145), the dormant wake-catcher (50-60), characterColumn captions (353-381),
//      topText status (386-395), wake() (408-411).
//    - Stage/StageBackground.swift  — the back-of-sandwich ZStack (19-49).
//    - Stage/CaptionsView.swift     — the ephemeral attributed caption (12-33).
//
//  THE ROUTER SEAM (the whole point of this file): the model stays decoupled from UI ownership.
//  ConversationModel exposes `componentSurfaceRouter` / `noteRequest`; the foreground wires them to
//  the shared SurfaceStore. One source of truth; cards are never double-rendered. (StageForeground.swift:88-93, 142-145)
//
//  CUTS for MVP: the Hub sheet (HubView); the dismiss/collect/park agent providers (:97-115); the
//  scenePhase persistence flush + resurfaceDueParked (:124-137); MotionManager parallax; the
//  ArrivalVeil iris animation (a plain dim is fine); the ThumbZoneBar (replace with one Rest/Wake
//  control); ~150 lines of #if DEBUG seeders (:146-346).
//
//  DEPENDENCIES: ConversationModel (.state/.pebblesText/.userText/.noteRequest/.componentSurfaceRouter
//  /.activeRemindersContextProvider/.start()) [slice 01]; SurfaceStore [this slice].

import SwiftUI

// MARK: - Foreground (front of the sandwich: captions, router wiring, dormant wake)

struct StageForeground: View {
    @Environment(ConversationModel.self) private var convo
    @Environment(SurfaceStore.self) private var store

    var body: some View {
        ZStack {
            // Dormant wake-catcher: full-screen, interactive ONLY while dormant, at the BACK of this
            // stack so cards/controls win their own taps and every OTHER dormant tap wakes. SwiftUI
            // routes touches the greedy host receives to this view internally; the UIKit stage only
            // intercepts AWAKE stone taps ahead of the host, so this never fights poke routing.
            // (Source: StageForeground.swift:50-60)
            if convo.state == .dormant {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { convo.start() }
                    .accessibilityElement()
                    .accessibilityLabel("Wake")
                    .accessibilityAddTraits(.isButton)
            }

            characterColumn   // captions + the transparent character reservation

            // (Cards are UIKit on the FloatingCanvas BELOW this host — not drawn here, so they're
            //  never double-rendered. A minimal controls strip would go here.)
        }
        .onAppear {
            // Bridge the surface source of truth to the session: the manager reads this at connect to
            // know what's on the glass. (Source: StageForeground.swift:84-87)
            let store = store
            convo.activeRemindersContextProvider = { [weak store] in store?.contextBlock() ?? "" }
            // THE ROUTER SEAM: route agent-selected components (and malformed tool calls → fallback)
            // to the SAME store/canvas. (Source: StageForeground.swift:91-93)
            convo.componentSurfaceRouter = { [weak store] request in store?.present(request: request) }
        }
        // Live content: when the session surfaces a search/tool answer (timed to when the agent speaks
        // it), turn it into a floating surface. A fresh id per request fires this even for identical
        // text. (Source: StageForeground.swift:142-145)
        .onChange(of: convo.noteRequest) { _, request in
            guard let request else { return }
            store.composeNote(content: request.content)
        }
    }

    /// The character rests lower-center: a flexible top spacer pushes a transparent reservation down
    /// toward the thumb zone, with captions tucked just beneath. The full-screen SKView renders the
    /// character BEHIND this reservation. (Source: StageForeground.swift:353-381, trimmed.)
    private var characterColumn: some View {
        VStack(spacing: 0) {
            Spacer()
            Color.clear.frame(height: 360)   // the character's reserved band (SKView draws behind it)
            Caption(text: topText, emphasized: !convo.pebblesText.isEmpty)
                .padding(.top, 8).padding(.horizontal, 32)
            Caption(text: convo.userText, emphasized: false)
                .padding(.top, 8).padding(.horizontal, 32)
            Color.clear.frame(height: 96)    // reserve the controls footprint
        }
    }

    /// The agent's live words when talking; otherwise a soft status so the user always knows what's
    /// happening. Dormant is intentionally blank. (Source: StageForeground.swift:386-395)
    private var topText: String {
        if !convo.pebblesText.isEmpty { return convo.pebblesText }
        switch convo.state {
        case .connecting: return "Waking up…"
        case .thinking:   return "Thinking…"
        case .searching:  return "Looking that up…"
        case .listening:  return "Listening"
        default:          return ""
        }
    }
}

// MARK: - Background (back of the sandwich)

/// Everything that draws BEHIND the character. The full app layers a mood-driven Metal field +
/// frosted-glass overlay + arrival veil; the MVP can be a calm gradient. Non-interactive.
/// (Source: StageBackground.swift:19-49.)
struct StageBackground: View {
    @Environment(ConversationModel.self) private var convo
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            // Full app: LivingBackground(...) + FrostedGlassOverlay() + ArrivalVeil(convo:) here.
        }
    }
}

// MARK: - Caption (ephemeral, attributed — not a chat log)

/// The agent's words read larger/warmer near the character; the user's words read quieter, lower,
/// near their thumb. Capped at 3 lines and bounded Dynamic Type. (Source: CaptionsView.swift:12-33)
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
