//  App.swift
//  The app entry point. It owns the ONE process-lifetime `ConversationModel` (so audio/session lifetime
//  is independent of any view — N4/N5), stands up the component registry once at launch, and renders
//  the UIKit stage edge-to-edge. The old `RootView` / `ConversationScreen` are gone: their controls,
//  captions, and key-sheet now live in `StageForeground`.

import SwiftUI

@main
struct MinimalRealtimeKitApp: App {
    /// The single shared conversation model for the whole process (created here, never per-view).
    @State private var conversation = ConversationModel()

    init() {
        // Stand up the agent-driven component registry once at launch (empty for v1; Tier 4 fills it).
        CompositionRoot.registerComponents()
    }

    var body: some Scene {
        WindowGroup {
            StageHost(conversation: conversation)
                .ignoresSafeArea()
        }
    }
}
