import SwiftUI

/// Root of the app. T1.3 hosts the minimal realtime voice screen (connect/stop, mute, live
/// captions, BYO-key entry). Later tiers replace this with the Stage composition
/// (background ‹ SpriteKit character ‹ floating cards ‹ foreground). The single owned
/// `ConversationModel` lives at the screen root inside `ConversationScreen` (SPEC N4/N5).
struct RootView: View {
    var body: some View {
        ConversationScreen()
    }
}

#Preview {
    RootView()
}
