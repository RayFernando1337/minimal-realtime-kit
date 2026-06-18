//  StageHost.swift
//  T3.0 — the bridge from the SwiftUI shell into the UIKit stage.
//
//  The app entry renders this `UIViewControllerRepresentable` edge-to-edge (`.ignoresSafeArea()`); it
//  builds the one `StageViewController`. The shared `ConversationModel` is injected here and only
//  READ by the VC/scene (N4 — a view/VC never owns audio or the session).

import SwiftUI

struct StageHost: UIViewControllerRepresentable {
    let conversation: ConversationModel

    func makeUIViewController(context: Context) -> StageViewController {
        StageViewController(conversation: conversation)
    }

    func updateUIViewController(_ vc: StageViewController, context: Context) {}
}
