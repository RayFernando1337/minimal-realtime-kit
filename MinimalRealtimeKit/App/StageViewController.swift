//  StageViewController.swift
//  T3.0 — the architectural pivot: UIKit owns composition, lifecycle, and interaction. The VC builds
//  the four-layer "sandwich" and bridges the @Observable model into the SKView character.
//
//        ┌─────────────────────────────────────────────┐  z-order, back → front
//        │ foregroundHost  UIHostingController(SwiftUI) │  captions, controls, dormant wake-catcher
//        │ cardCanvas      PassthroughContainerView    │  the cards layer (EMPTY placeholder for v1)
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

// MARK: - Passthrough card layer (transparent to touches in empty space)

/// The cards layer: transparent to touches in empty space, claims only its real children. For v1 it
/// has NO children (it renders nothing) — a later card (Tier 4) installs a FloatingCanvas here that
/// renders the agent-driven cards. The passthrough behavior is what keeps the reversed-priority
/// routing working: a touch that misses every card falls through to the orb / foreground beneath.
final class PassthroughContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit   // empty space → fall through to the layers below
    }
}

// MARK: - Reversed-priority root

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
    private let cardCanvas = PassthroughContainerView()
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
        installCardCanvas()       // the cards, passthrough (empty for v1)
        installForegroundHost()   // front of the sandwich
        wireRouting()
        observeReduceMotion()
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

    /// Install the passthrough card canvas ABOVE the SKView and BELOW the foreground host. It returns
    /// nil in empty space so it never steals orb routing or foreground controls. EMPTY for v1.
    private func installCardCanvas() {
        cardCanvas.backgroundColor = .clear
        pin(cardCanvas, to: view)
        // Tier 4 (the agent-driven cards card) adds a FloatingCanvas inside this layer that renders
        // the SurfaceStore. Until then it draws nothing — the placeholder only preserves the
        // reversed-priority hit-test seam so dropping cards in later needs no spine change.
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
        rootView.cardCanvas = cardCanvas
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
