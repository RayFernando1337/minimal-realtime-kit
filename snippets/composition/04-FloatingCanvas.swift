//
//  04-FloatingCanvas.swift  (DISTILLED MVP — illustrative, not copied verbatim)
//
//  The passthrough UIKit layer between the SKView (character) and the SwiftUI foreground host. It
//  renders the store's floating set as `CardViewController`s and keeps them in sync. The full version
//  is 531 lines (free-placement solver, edge tuck, pocket collapse/expand, collect match-move,
//  Pebbles reservation band, materialize haptics, Dynamic Type re-measure). This is the MVP core:
//  a passthrough container + sync() that diffs the store + a simple bottom-stack layout.
//
//  Provenance: Stage/FloatingCanvas.swift — PassthroughContainerView (30-35), the controller +
//  sync() (40-229), makeBody via the factory (234-249), detach (251-255).
//
//  CUTS for MVP (all in the original): the pocket/spine tab + collect-board handoffs (onSpineTap/
//  onRequestCollect, :57-66, 373-426); free-placement denormalize/normalize/clamp + edge-tuck
//  display centers (:428-530); the Pebbles reservation safe-zone solver (:78-96, 524-530); the P10
//  materialize haptic de-dup (:48-55, 168-225); the trait-change re-measure (:127-131).
//
//  DEPENDENCIES: SurfaceStore [this slice]; ComponentFactory / ComponentRequest / FactoryContext /
//  FallbackComponentVC [slice 02].

import UIKit

// MARK: - Passthrough container (transparent to touches in empty space)

/// Floating-UI layer: transparent to touches in empty space, claims only its real children (cards).
/// This is what lets a touch that misses every card fall through to the stone routing / SwiftUI UI
/// beneath, preserving the stage's reversed-priority routing. (Source: FloatingCanvas.swift:30-35)
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
    /// Live cards keyed by surface id (the diffing identity). (Source: FloatingCanvas.swift:44)
    private var cards: [UUID: CardViewController] = [:]

    init(store: SurfaceStore) {
        self.store = store
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
        applyLayout(animated: false)   // reposition on rotation / size-class change
    }

    // MARK: Sync (driven by StageViewController.updateProperties → observation)

    /// Reconcile the live cards with the store's floating set, then lay out. Bodies come from the
    /// ComponentFactory (note → real body; unknown/bad/malformed → the mandatory fallback) — never
    /// discarded, never a crash. Removing a card tears down ONLY its own views (never audio).
    /// (Source: FloatingCanvas.swift:154-229, trimmed.)
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
            // MVP: a swipe-flick DISMISSES the card. (The full app COLLECTS it to a board instead —
            // a recoverability model where nothing is deleted from the glass.)
            card.onDismiss = { [weak self] id in self?.store.dismiss(id: id) }
            cards[surface.id] = card
            addChild(card)
            view.addSubview(card.view)
            card.didMove(toParent: self)
            card.materialize(animated: true)
        }

        applyLayout(animated: true)
    }

    /// Build the body for a surface. Fallback surfaces render the mandatory FallbackComponentVC;
    /// everything else goes through the registry, which itself degrades unknown ids / bad payloads to
    /// the fallback at build time. Either way the result is presentable. (Source: FloatingCanvas.swift:234-249)
    private func makeBody(for surface: Surface) -> UIViewController {
        if surface.isFallback { return FallbackComponentVC(reason: .malformedToolCall) }
        let request = ComponentRequest(id: surface.componentID, payload: surface.payload)
        return ComponentFactory.shared.make(request, context: FactoryContext(ownsCardChrome: false))
    }

    private func detach(_ card: CardViewController) {
        card.willMove(toParent: nil)
        card.view.removeFromSuperview()
        card.removeFromParent()
    }

    // MARK: Layout (MVP: a simple bottom-anchored stack)

    /// MVP layout: stack the cards from the bottom, newest lowest, in zIndex order. The full app's
    /// solver does free placement (a dropped card stays put), an upper-band thumb stack that keeps
    /// auto-placed cards above the character, edge tuck, and pocket collapse — all CUT here.
    private func applyLayout(animated: Bool) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let safe = view.safeAreaInsets
        let floating = store.floatingSurfaces

        let frontID = floating.max(by: { $0.zIndex < $1.zIndex })?.id
        var y = bounds.maxY - safe.bottom - 24
        for surface in floating.sorted(by: { $0.zIndex > $1.zIndex }) {   // front (highest z) lowest
            guard let card = cards[surface.id], !card.isInteracting else { continue }
            let size = card.preferredSize()
            card.isFrontCard = (surface.id == frontID)
            card.baseTilt = CGFloat(surface.tilt) * .pi / 180
            card.view.layer.zPosition = CGFloat(surface.zIndex)
            card.view.bounds = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: bounds.midX, y: y - size.height / 2)
            card.place(restingCenter: center, animated: animated)
            y -= 40   // title-peek overlap so a stack reads as "more behind"
        }
    }
}
