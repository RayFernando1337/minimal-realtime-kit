//  StageViewController.swift
//  T3.0 — the architectural pivot: UIKit owns composition, lifecycle, and interaction. The VC builds
//  the four-layer "sandwich" and bridges the @Observable model into the SKView character.
//
//        ┌─────────────────────────────────────────────┐  z-order, back → front
//        │ foregroundHost  UIHostingController(SwiftUI) │  captions, controls, dormant wake-catcher
//        │ floatingCanvas  FloatingCanvasController     │  the agent-driven cards (T4.3)
//        │ skView          SKView(CharacterScene)      │  the character (full-bleed)
//        │ backgroundHost  UIHostingController(SwiftUI) │  calm dark gradient
//        └─────────────────────────────────────────────┘
//
//  WHY UIKIT OWNS COMPOSITION (the load-bearing reason): a full-screen `UIHostingController` is
//  GREEDY — `hitTest` "doesn't take the view's content into account" (Apple docs), so a SwiftUI host
//  claims its WHOLE bounds and can't return nil over empty space. To put a full-screen SKView
//  character UNDER a full-screen SwiftUI UI and still let a tap on the orb reach it, the stage uses a
//  UIKit root with REVERSED-PRIORITY hitTest: cards win first; then a node-precise orb tap → the
//  SKView; then everything else falls to the greedy foreground host, which SwiftUI routes internally.
//
//  N4: this VC NEVER owns audio/session — it only READS `conversation.state` / `currentLevel()` and
//  (via the foreground island) calls start()/stop()/setMuted(). There is no `deinit`.
//  N6: the ~50×/s audio level is pulled per-frame by the scene's `levelProvider`; observation
//  (`updateProperties`) carries ONLY the discrete state.

import SwiftUI
import UIKit
import SpriteKit

// MARK: - Reversed-priority root
//
// NOTE: the cards layer is a `PassthroughContainerView` — it returns nil in empty space so non-card
// touches fall through to the orb routing / foreground. That type now lives in `FloatingCanvas.swift`
// (the canvas owns it); the root below only needs a `UIView` reference to it via `cardCanvas`.

/// Stage root. Cards win first (a card over the orb stays draggable); then a precise orb tap goes to
/// the character; then everything else falls through to the greedy foreground host, which routes it
/// internally via SwiftUI. The card canvas's passthrough (nil in empty space) is what lets non-card
/// touches reach the orb routing / foreground.
final class StageRootView: UIView {
    weak var skView: UIView?
    weak var cardCanvas: UIView?          // the PassthroughContainerView
    /// Returns true when the character should claim `point` (root coords): an orb hit while awake.
    var stageWantsTouch: ((CGPoint) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 1) Cards win; the passthrough canvas returns nil in empty space so non-card touches continue.
        if let canvas = cardCanvas {
            let pInCanvas = convert(point, to: canvas)
            if let hit = canvas.hitTest(pInCanvas, with: event) { return hit }
        }
        // 2) A precise orb tap → the character.
        if let skView, stageWantsTouch?(point) == true { return skView }
        // 3) Everything else → the greedy foreground host via super (SwiftUI routes it internally).
        return super.hitTest(point, with: event)
    }
}

// MARK: - Stage view controller (the coordinator)

final class StageViewController: UIViewController {
    private let conversation: ConversationModel

    private var backgroundHost: UIHostingController<AnyView>?
    private var foregroundHost: UIHostingController<AnyView>?
    /// The agent-driven cards layer (T4.3). Reads the shared `SurfaceStore`; a `choice` pick rides
    /// back to the model as a new user turn. The model owns audio/session, never this canvas (N4).
    private let floatingCanvas: FloatingCanvasController
    private let skView = SKView()
    private let scene = CharacterScene(size: CGSize(width: 402, height: 874))

    #if DEBUG
    // Screenshot/QA harness (DEBUG only — compiled out of Release). Lets the sandwich + character be
    // verified headlessly without a live key/mic: pin a discrete pose (MRK_UI_STATE) and/or a fake
    // audio level (MRK_LEVEL 0–100). Invariant-safe: it only feeds `scene.apply(state:)` / the level
    // closure — it never touches audio/session and adds no `response.create`.
    private let debugState: PebblesState? = StageDebugEnv.state
    private let debugLevel: Float? = StageDebugEnv.level
    #endif

    init(conversation: ConversationModel) {
        self.conversation = conversation
        // The cards canvas reads the shared store; an interactive `choice` pick rides back to the
        // model as a NEW user turn (sendUserChoice — response.create SITE 2, never a new one).
        self.floatingCanvas = FloatingCanvasController(
            store: CompositionRoot.surfaceStore,
            onUserChoice: { [weak conversation] text in conversation?.sendUserChoice(text) }
        )
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The discrete state the character should reflect — `conversation.state` in production; a pinned
    /// pose in DEBUG screenshot runs.
    private var resolvedState: PebblesState {
        #if DEBUG
        if let debugState { return debugState }
        #endif
        return conversation.state
    }

    private var rootView: StageRootView { view as! StageRootView }
    override func loadView() { view = StageRootView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureScene()
        installBackgroundHost()   // back of the sandwich
        installSKView()           // the character, full-bleed
        installCardCanvas()       // the agent-driven cards (passthrough)
        installForegroundHost()   // front of the sandwich
        wireRouting()
        observeReduceMotion()
        #if DEBUG
        seedDemoCardsIfRequested()   // MRK_DEMO_CARDS=1 → render cards on the glass with no session
        #endif
        // Kick the first observation-tracked pass. iOS 26 re-invokes updateProperties() automatically
        // when the read @Observable values change.
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scene.apply(state: resolvedState)   // seed the first-frame pose
    }

    // MARK: Observation — discrete state only (NEVER the per-frame audio meter, N6)

    /// Reading `conversation.state` registers a dependency; UIKit re-runs this when it changes (iOS 26
    /// automatic observation tracking). The ~50×/s audio meter is deliberately kept OFF this path —
    /// the scene samples it per-frame via `levelProvider`, so layout/observation never churns at
    /// audio rate.
    override func updateProperties() {
        super.updateProperties()
        scene.apply(state: resolvedState)
        // Register the surface dependency so iOS-26 observation re-invokes this when cards change,
        // then reconcile the canvas. The ~50×/s audio meter stays OFF this path (N6).
        _ = CompositionRoot.surfaceStore.floatingSurfaces
        floatingCanvas.sync()
    }

    // MARK: Setup

    private func configureScene() {
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        // The VC owns touch routing — disable the scene's catch-all so poke is driven from the
        // hit-test (an orb hit while awake).
        scene.isUserInteractionEnabled = false
        scene.reduceMotion = UIAccessibility.isReduceMotionEnabled
        // N6: live voice level is sampled per-frame IN the scene (off observation/layout).
        #if DEBUG
        let pinnedLevel = debugLevel
        #endif
        scene.levelProvider = { [weak conversation] in
            #if DEBUG
            if let pinnedLevel { return pinnedLevel }
            #endif
            return conversation?.currentLevel() ?? 0
        }
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
        skView.presentScene(scene)
        pin(skView, to: view)   // full-bleed: the character roams the whole screen
    }

    /// Install the cards canvas ABOVE the SKView and BELOW the foreground host. Its
    /// `PassthroughContainerView` returns nil in empty space so it never steals orb routing or
    /// foreground controls; it renders the shared `SurfaceStore` as draggable glass cards (T4.3).
    private func installCardCanvas() {
        addChild(floatingCanvas)
        floatingCanvas.view.backgroundColor = .clear
        pin(floatingCanvas.view, to: view)
        floatingCanvas.didMove(toParent: self)
    }

    private func installForegroundHost() {
        let root = StageForeground().environment(conversation)
        let host = UIHostingController(rootView: AnyView(root))
        foregroundHost = host
        addChild(host)
        host.view.backgroundColor = .clear
        pin(host.view, to: view)
        host.didMove(toParent: self)
    }

    private func wireRouting() {
        rootView.skView = skView
        rootView.cardCanvas = floatingCanvas.view
        // Route model-selected cards (the `.component` event) to the shared store. The model never
        // imports the store — clean inversion of control. A nil request still lands as the mandatory
        // fallback on the glass (N3). This adds NO response.create (N2).
        conversation.componentSurfaceRouter = { [weak store = CompositionRoot.surfaceStore] request in
            store?.present(request: request)
        }
        rootView.stageWantsTouch = { [weak self] pointInRoot in
            guard let self else { return false }
            // Dormant wake is handled by the SwiftUI wake-catcher in the foreground; otherwise claim
            // only a precise orb tap.
            guard self.conversation.state != .dormant else { return false }
            let pInSK = self.rootView.convert(pointInRoot, to: self.skView)
            return self.scene.stoneHit(atViewPoint: pInSK)
        }
        // A quick tap on the orb pokes the character. (Character drag/long-press is a later stretch.)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStageTap(_:)))
        skView.addGestureRecognizer(tap)
    }

    @objc private func handleStageTap(_ gesture: UITapGestureRecognizer) {
        let pInSK = gesture.location(in: skView)
        if scene.stoneHit(atViewPoint: pInSK) { scene.poke() }
    }

    // MARK: Accessibility

    private func observeReduceMotion() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil)
    }

    @objc private func reduceMotionChanged() {
        scene.reduceMotion = UIAccessibility.isReduceMotionEnabled
        scene.apply(state: conversation.state)   // re-resolve the pose (zeroes breath/bounce)
    }

    #if DEBUG
    // MARK: Screenshot/QA — seed representative cards with no live session

    /// `SIMCTL_CHILD_MRK_DEMO_CARDS=1` (→ env `MRK_DEMO_CARDS`) seeds a representative set straight
    /// into the shared store so cards render headlessly (no key/mic): a `stat_card`, an interactive
    /// `choice`, AND a malformed tool call (a nil request → the mandatory "Couldn't show that"
    /// fallback on the glass, proving N3). The first `updateProperties()` pass syncs them onto the
    /// canvas. Inert when unset; never touches audio/session and adds no response.create.
    private func seedDemoCardsIfRequested() {
        guard ProcessInfo.processInfo.environment["MRK_DEMO_CARDS"] == "1" else { return }
        let store = CompositionRoot.surfaceStore

        store.present(request: ComponentRequest(id: .statCard, payload: .object([
            "eyebrow": .string("THIS WEEK"),
            "metric": .string("$1,240"),
            "title": .string("Travel budget"),
            "modules": .array([
                .object(["label": .string("Flights"), "value": .string("$820")]),
                .object(["label": .string("Hotel"), "value": .string("$420")]),
            ]),
        ])))

        store.present(request: ComponentRequest(id: .choice, payload: .object([
            "prompt": .string("Want me to book the 9am?"),
            "options": .array([
                .object(["id": .string("book"), "label": .string("Yes, book it")]),
                .object(["id": .string("hold"), "label": .string("Not yet")]),
            ]),
        ])))

        // A malformed / undecodable tool call → nil request → the mandatory fallback card (N3 on glass).
        store.present(request: nil)
    }
    #endif

    // MARK: Layout helper

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

#if DEBUG
// MARK: - Screenshot/QA env (DEBUG only — never compiled into Release)

/// Tiny env-driven harness so the character/sandwich can be verified headlessly (the repo has no test
/// target/CI; the sim-screenshot loop is the only safety net). Set on launch via
/// `SIMCTL_CHILD_MRK_UI_STATE=speaking SIMCTL_CHILD_MRK_LEVEL=70 xcrun simctl launch …`.
enum StageDebugEnv {
    /// Pin a discrete pose (no live session needed).
    static var state: PebblesState? {
        switch ProcessInfo.processInfo.environment["MRK_UI_STATE"]?.lowercased() {
        case "dormant":    return .dormant
        case "connecting": return .connecting
        case "idle":       return .idle
        case "listening":  return .listening
        case "thinking":   return .thinking
        case "searching":  return .searching
        case "speaking":   return .speaking
        default:           return nil
        }
    }

    /// Pin a fake amplitude (0–100 → 0…1) so the speaking swell / listening draw-in / smile-on-peak
    /// are visible in a still.
    static var level: Float? {
        guard let raw = ProcessInfo.processInfo.environment["MRK_LEVEL"], let v = Float(raw) else { return nil }
        return max(0, min(1, v / 100))
    }
}
#endif
