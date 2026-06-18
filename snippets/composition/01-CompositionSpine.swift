//
//  01-CompositionSpine.swift  (DISTILLED MVP — illustrative, not copied verbatim)
//
//  The entry spine: @main App → CompositionRoot (DI) → StageHost (UIViewControllerRepresentable)
//  → StageViewController hosting the three-layer "sandwich".
//
//  Provenance (Pebbles / OpenAIRealtimeSample):
//    - OpenAIRealtimeSampleApp.swift:10-46   (@main, appRoot, .ignoresSafeArea)
//    - App/CompositionRoot.swift:9-91        (DI singletons + registerComponents)
//    - App/StageHost.swift:7-15              (UIViewControllerRepresentable)
//    - App/SwiftUIViewController.swift:6-10  (the one SwiftUI→UIKit hosting bridge)
//
//  REDACTION: no secrets exist in these files (keys/URLs live in RealtimeManager, not here).
//  CUTS for MVP: the DEBUG PebblesLab branch; registering 9 components (keep `.note` only,
//  plus the fallback). MotionManager is optional (drop if you don't render a parallax background).
//
//  DEPENDENCIES (other workers' slices): ConversationModel + RealtimeManager (01-realtime-core),
//  ComponentFactory / ComponentID / NotePayload (02-factory-pattern).

import SwiftUI
import UIKit

// MARK: - @main App  (the SwiftUI shell owns the process-lifetime models)

@main
struct MinimalRealtimeApp: App {
    // The ONE shared conversation model for the whole process. Created here (never per-view) so
    // audio/session lifetime is independent of any view. (Source: OpenAIRealtimeSampleApp.swift:12)
    @State private var conversation = ConversationModel()

    init() {
        // Stand up the agent-driven component registry once, at launch. (CompositionRoot.swift:20)
        CompositionRoot.registerComponents()
    }

    var body: some Scene {
        WindowGroup {
            // The representable fills the window edge-to-edge; the hosted SwiftUI islands manage
            // their own safe area. (Source: OpenAIRealtimeSampleApp.swift:43-44)
            StageHost(conversation: conversation, surfaceStore: CompositionRoot.surfaceStore)
                .ignoresSafeArea()
        }
    }
}

// MARK: - CompositionRoot  (the app's single DI root + factory registry)

/// One composition root. Holds the process-lifetime singletons and the component registry. A
/// `static let` is created lazily on first access and never re-instantiated, so there is exactly
/// ONE source of truth for what is on the glass. (Source: CompositionRoot.swift:9-14)
enum CompositionRoot {
    @MainActor static let surfaceStore = SurfaceStore()

    /// Register the app's component builders. App-owned (the model never touches this). Adding a
    /// component is one line here. MVP registers only `.note`; everything else routes to the
    /// mandatory fallback inside ComponentFactory. (Source: CompositionRoot.swift:20-29)
    @MainActor static func registerComponents() {
        ComponentFactory.shared.register(.note) { payload, context in
            let note = try payload.decode(NotePayload.self)
            guard let content = note.toPostItContent() else { throw ComponentBuildError.emptyNote }
            return context.host(NoteComponentView(content: content))
        }
        // (Pebbles registers 8 more ids here — choice/statCard/list/charts/etc. — all CUT for MVP.)
    }
}

// MARK: - StageHost  (UIKit island inside the SwiftUI shell)

/// The bridge from SwiftUI into the UIKit stage. The shared models are injected here and only READ
/// by the VC (the store is mutated through its own API, never re-instantiated). (StageHost.swift:7-15)
struct StageHost: UIViewControllerRepresentable {
    let conversation: ConversationModel
    let surfaceStore: SurfaceStore
    func makeUIViewController(context: Context) -> StageViewController {
        StageViewController(conversation: conversation, surfaceStore: surfaceStore)
    }
    func updateUIViewController(_ vc: StageViewController, context: Context) {}
}

// MARK: - SwiftUIViewController  (the ONE SwiftUI→UIKit hosting bridge)

/// Wrap any SwiftUI view in a hosting controller so the UIKit stage can host SwiftUI "leaf" bodies
/// (the background/foreground islands and the card bodies). (Source: SwiftUIViewController.swift:6-10)
final class SwiftUIViewController<Content: View>: UIHostingController<Content> {
    init(with rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
