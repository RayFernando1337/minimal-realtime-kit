//
//  02-StageViewController.swift  (DISTILLED MVP — illustrative, not copied verbatim)
//
//  The architectural gate: UIKit owns composition, lifecycle, and interaction. The VC builds the
//  three-layer "sandwich" and bridges @Observable model/store changes into the SKView + card canvas.
//
//        ┌─────────────────────────────────────────────┐  z-order, back → front
//        │ foregroundHost  UIHostingController(SwiftUI) │  captions, controls, dormant wake-catcher
//        │ floatingCanvas  PassthroughContainerView    │  the cards on glass (UIKit)
//        │ skView          SKView(PebblesScene)        │  the character (full-screen)
//        │ backgroundHost  UIHostingController(SwiftUI) │  living place + frost + arrival veil
//        └─────────────────────────────────────────────┘
//
//  WHY UIKIT OWNS COMPOSITION (the load-bearing reason): a single full-screen `UIHostingController`
//  is GREEDY — `hitTest` "doesn't take the view's content into account" (Apple docs), so a SwiftUI
//  host claims its WHOLE bounds and can't return nil over empty space. To put a full-screen SKView
//  character UNDER a full-screen SwiftUI UI and still let a tap on a *stone* reach the character,
//  the stage uses a UIKit root view with REVERSED-PRIORITY hitTest: it extracts a node-precise stone
//  tap to the SKView BEFORE the greedy foreground host; every other touch falls to the host and
//  SwiftUI routes it internally. (Source: App/StageViewController.swift:5-25, 33-69)
//
//  CUTS for MVP (all present in the 776-line original): the collect board + float⇄collect match-move
//  (installCollectBoard/collectWithMatchMove); the character DRAG/long-press (P3 — slice 03); the
//  react-to-elements glances (P9); rest/materialize haptics (P10); all DEBUG probes; the a11y element
//  mirror. Kept: sandwich install, reversed hitTest, observation→sync, a stone-tap → poke.
//
//  DEPENDENCIES: ConversationModel (.state/.tone/.currentLevel) [slice 01]; PebblesScene [slice 03].

import SwiftUI
import UIKit
import SpriteKit

// MARK: - Hit-test routing (the reversed-priority root)

/// Stage root. Cards win first (a card over the character stays draggable); then a precise stone tap
/// goes to the character; then everything else falls through to the greedy foreground host, which
/// routes it internally via SwiftUI. The canvas's passthrough (nil in empty space) is what lets
/// non-card touches reach the stone routing / foreground. (Source: StageViewController.swift:33-68)
final class StageRootView: UIView {
    weak var skView: UIView?
    weak var floatingCanvas: UIView?            // the PassthroughContainerView
    /// Returns true when the character should claim `point` (root coords): a stone hit while awake.
    var stageWantsTouch: ((CGPoint) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 1) Floating cards win; the passthrough canvas returns nil in empty space so non-card
        //    touches continue below, unchanged.
        if let canvas = floatingCanvas {
            let pInCanvas = convert(point, to: canvas)
            if let hit = canvas.hitTest(pInCanvas, with: event) { return hit }
        }
        // 2) A precise stone tap → the character.
        if let skView, stageWantsTouch?(point) == true { return skView }
        // 3) Everything else → the greedy foreground host via super (SwiftUI routes it internally).
        return super.hitTest(point, with: event)
    }
}

// MARK: - Stage view controller (the coordinator)

final class StageViewController: UIViewController {
    private let conversation: ConversationModel
    private let surfaceStore: SurfaceStore

    private var backgroundHost: UIHostingController<AnyView>?
    private var foregroundHost: UIHostingController<AnyView>?
    private var floatingCanvas: FloatingCanvasController?
    private let skView = SKView()
    private let pebblesScene = PebblesScene(size: CGSize(width: 402, height: 874))

    init(conversation: ConversationModel, surfaceStore: SurfaceStore) {
        self.conversation = conversation
        self.surfaceStore = surfaceStore
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var rootView: StageRootView { view as! StageRootView }
    override func loadView() { view = StageRootView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureScene()
        installBackgroundHost()   // back of the sandwich
        installSKView()           // the character, full-bleed
        installFloatingCanvas()   // the cards, passthrough
        installForegroundHost()   // front of the sandwich
        wireRouting()
        // Kick the first observation-tracked pass. iOS 26 re-invokes updateProperties() automatically
        // when the read @Observable values change. (Source: StageViewController.swift:165-167)
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pebblesScene.apply(state: conversation.state, tone: conversation.tone, animated: false)
    }

    // MARK: Observation — discrete state only (NEVER the per-frame audio meter)

    /// Reading these @Observable props registers a dependency; UIKit re-runs updateProperties() when
    /// they change (iOS 26 automatic observation tracking). The ~50×/s audio meter is deliberately
    /// kept OFF this path — the scene samples it per-frame via `levelProvider`, so layout/observation
    /// never churns at audio rate. (Source: StageViewController.swift:22-24, 189-217)
    override func updateProperties() {
        super.updateProperties()
        let state = conversation.state
        let tone = conversation.tone
        pebblesScene.apply(state: state, tone: tone)
        // Reading the floating set registers the dependency so this re-runs on add/remove/reorder;
        // sync the UIKit card canvas to the store.
        _ = surfaceStore.floatingSurfaces
        floatingCanvas?.sync()
    }

    // MARK: Setup

    private func configureScene() {
        pebblesScene.scaleMode = .resizeFill
        pebblesScene.backgroundColor = .clear
        // The VC owns touch routing — disable the scene's catch-all so poke is driven from the
        // hit-test (a stone hit while awake). (Source: StageViewController.swift:224-226)
        pebblesScene.isUserInteractionEnabled = false
        // Live voice level is sampled per-frame IN the scene (off observation/layout).
        pebblesScene.levelProvider = { [weak conversation] in conversation?.currentLevel() ?? 0 }
    }

    private func installBackgroundHost() {
        let root = StageBackground().environment(conversation)
        let host = UIHostingController(rootView: AnyView(root))
        backgroundHost = host
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false   // no controls behind the character
        pin(host.view, to: view)
        host.didMove(toParent: self)
    }

    private func installSKView() {
        skView.translatesAutoresizingMaskIntoConstraints = false
        skView.backgroundColor = .clear
        skView.isOpaque = false
        skView.allowsTransparency = true
        skView.presentScene(pebblesScene)
        pin(skView, to: view)   // full-bleed: the character roams the whole screen
    }

    /// Install the passthrough card canvas ABOVE the SKView and BELOW the foreground host. It returns
    /// nil in empty space so it never steals stone routing or foreground controls.
    private func installFloatingCanvas() {
        let canvas = FloatingCanvasController(store: surfaceStore)
        floatingCanvas = canvas
        addChild(canvas)
        canvas.view.backgroundColor = .clear
        pin(canvas.view, to: view)
        canvas.didMove(toParent: self)
    }

    private func installForegroundHost() {
        let root = StageForeground()
            .environment(conversation)
            .environment(surfaceStore)   // the SAME store the canvas renders (one source of truth)
        let host = UIHostingController(rootView: AnyView(root))
        foregroundHost = host
        addChild(host)
        host.view.backgroundColor = .clear
        pin(host.view, to: view)
        host.didMove(toParent: self)
    }

    private func wireRouting() {
        rootView.skView = skView
        rootView.floatingCanvas = floatingCanvas?.view
        rootView.stageWantsTouch = { [weak self] pointInRoot in
            guard let self else { return false }
            // Dormant wake is handled by the SwiftUI wake-catcher in the foreground; otherwise claim
            // only a precise stone tap. (Source: StageViewController.swift:333-340)
            guard self.conversation.state != .dormant else { return false }
            let pInSK = self.rootView.convert(pointInRoot, to: self.skView)
            return self.pebblesScene.stoneHit(atViewPoint: pInSK)
        }
        // A quick stationary tap on a stone pokes the character. (The full app adds pan+long-press
        // for dragging the character — CUT here; see slice 03.)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStageTap(_:)))
        skView.addGestureRecognizer(tap)
    }

    @objc private func handleStageTap(_ gesture: UITapGestureRecognizer) {
        let pInSK = gesture.location(in: skView)
        if pebblesScene.stoneHit(atViewPoint: pInSK) { pebblesScene.poke() }
    }

    private func pin(_ child: UIView, to parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}
