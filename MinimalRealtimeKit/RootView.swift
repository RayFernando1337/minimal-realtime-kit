import SwiftUI

/// Placeholder root for the Tier 0 skeleton. Later tiers replace this with the
/// Stage composition (background ‹ SpriteKit character ‹ floating cards ‹ foreground).
struct RootView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.10),
                    Color(red: 0.10, green: 0.11, blue: 0.16)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("minimal-realtime-kit")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("BYO-key GPT Realtime voice agent")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

#Preview {
    RootView()
}
