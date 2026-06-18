//  FloatingCanvas.swift
//  T4.3 — the passthrough UIKit layer between the SKView (character) and the SwiftUI foreground host.
//  It renders the store's floating set as `CardViewController`s and keeps them in sync. The full
//  Pebbles canvas is 531 lines (free-placement solver, edge tuck, pocket collapse/expand, collect
//  match-move, reservation band, materialize haptics, Dynamic Type re-measure). This is the MVP core:
//  a passthrough container + `sync()` that diffs the store + a simple bottom-anchored stack.
//
//  `sync()` is driven by `StageViewController.updateProperties()` (iOS 26 observation): it diffs
//  `store.floatingSurfaces` vs the live cards (add / remove), builds each body through the factory
//  (note/choice/statCard → a real body; unknown id / bad payload / a fallback surface → the mandatory
//  `FallbackComponentVC`), wraps it in a `CardViewController`, and lays them out. A removed card tears
//  down ONLY its own views (N4 — never audio / the session).

import UIKit

// MARK: - Passthrough container (transparent to touches in empty space)

/// The cards layer: transparent to touches in empty space, claims only its real children (cards).
/// This is the hinge of the stage's reversed-priority routing — a touch that misses every card falls
/// through to the orb routing / SwiftUI foreground beneath. (This type used to live in
/// StageViewController; it moved here so the canvas owns it and there's no duplicate.)
final class PassthroughContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit   // empty space → fall through to the layers below
    }
}

// MARK: - Floating canvas controller

@MainActor
final class FloatingCanvasController: UIViewController {
    private let store: SurfaceStore
    /// The behavior seam for interactive cards: a `choice` pick rides this back to the model as a NEW
    /// user turn (the stage wires it to `ConversationModel.sendUserChoice`). The model never ships a
    /// callback — only DATA (N3).
    private let onUserChoice: (String) -> Void

    /// Live cards keyed by surface id (the diffing identity).
    private var cards: [UUID: CardViewController] = [:]

    /// MVP layout: lift the stack above the bottom thumb-zone controls (mute + connect) so cards stay
    /// visible. The full app runs a real placement solver that reserves a band above the character.
    private let bottomControlsInset: CGFloat = 188

    init(store: SurfaceStore, onUserChoice: @escaping (String) -> Void) {
        self.store = store
        self.onUserChoice = onUserChoice
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = PassthroughContainerView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLayout(animated: false)   // reposition on rotation / size-class change / first valid bounds
    }

    // MARK: Sync (driven by StageViewController.updateProperties → observation)

    /// Reconcile the live cards with the store's floating set, then lay out. Removing a card tears down
    /// ONLY its own views (N4); bodies come from the factory, which never crashes and never returns nil.
    func sync() {
        let floating = store.floatingSurfaces
        let desiredIDs = Set(floating.map(\.id))

        // Remove cards whose surface left the floating set.
        for (id, card) in cards where !desiredIDs.contains(id) {
            cards[id] = nil
            card.dematerialize { [weak self] in self?.detach(card) }
        }

        // Add cards for newly-floating surfaces.
        for surface in floating where cards[surface.id] == nil {
            let card = CardViewController(surfaceID: surface.id, bodyVC: makeBody(for: surface))
            card.onBringToFront = { [weak self] id in
                self?.store.bringToFront(id: id)
                if let card = self?.cards[id] { self?.view.bringSubviewToFront(card.view) }
            }
            // MVP: a swipe-flick DISMISSES the card. (The full app COLLECTS it to a board instead.)
            card.onDismiss = { [weak self] id in self?.store.dismiss(id: id) }
            cards[surface.id] = card
            addChild(card)
            view.addSubview(card.view)
            card.didMove(toParent: self)
            card.materialize(animated: true)
        }

        applyLayout(animated: true)
    }

    /// Build the body for a surface. A fallback surface (a malformed tool call) renders the mandatory
    /// `FallbackComponentVC`; everything else goes through the registry, which itself degrades an
    /// unknown id / bad payload to the fallback at build time. Either way the result is presentable (N3).
    private func makeBody(for surface: Surface) -> UIViewController {
        if surface.isFallback { return FallbackComponentVC(reason: .malformedToolCall) }
        let request = ComponentRequest(id: surface.componentID, payload: surface.payload)
        let context = FactoryContext(
            onUserChoice: onUserChoice,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            ownsCardChrome: false   // the card supplies the glass chrome; the body renders content only
        )
        return ComponentFactory.shared.make(request, context: context)
    }

    private func detach(_ card: CardViewController) {
        card.willMove(toParent: nil)
        card.view.removeFromSuperview()
        card.removeFromParent()
    }

    // MARK: Layout (MVP: a simple bottom-anchored stack, lifted above the thumb-zone controls)

    /// Stack the cards from the bottom of the visible band, the front (highest z) lowest, with a small
    /// title-peek overlap so a stack reads as "more behind." The full app's solver does free placement,
    /// an upper thumb band, edge tuck, and pocket collapse — all CUT here.
    private func applyLayout(animated: Bool) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let safe = view.safeAreaInsets
        let floating = store.floatingSurfaces

        let frontID = floating.max(by: { $0.zIndex < $1.zIndex })?.id
        var y = bounds.maxY - safe.bottom - bottomControlsInset
        for surface in floating.sorted(by: { $0.zIndex > $1.zIndex }) {   // front (highest z) lowest
            guard let card = cards[surface.id], !card.isInteracting else { continue }
            let size = card.preferredSize()
            card.isFrontCard = (surface.id == frontID)
            card.baseTilt = CGFloat(surface.tilt) * .pi / 180
            card.view.layer.zPosition = CGFloat(surface.zIndex)
            card.view.bounds = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: bounds.midX, y: y - size.height / 2)
            card.place(restingCenter: center, animated: animated)
            y -= 44   // title-peek overlap so a stack reads as "more behind"
        }
    }
}
