//  CardViewController.swift
//  T4.3 — one draggable floating card: a factory-built body inside a Liquid-Glass host, with
//  drag-to-move, swipe-flick-to-dismiss, bring-to-front, and a materialize / dematerialize that
//  animates the glass `.effect` (NEVER `alpha` — alpha on glass looks wrong). The full Pebbles card
//  is 764 lines (edge tuck, collect-on-flick, pocket collapse, shimmer + sparkle reveal,
//  interactive-body gesture yielding, VoiceOver actions); this is the MVP.
//
//  N4 (load-bearing): this VC owns NOTHING about audio / the session. Its `deinit` releases ONLY
//  views — a card deallocating must never tear down a turn. There is no audio/session reference here
//  to release.
//
//  THE CARD-SIZING LANDMINE (keep this): a `UIHostingController`'s intrinsic size is CORRUPTED by a
//  SCALE transform on an ancestor — under a held card's 0.94 depth scale it shrinks and oscillates,
//  desyncing the glass frame from the SwiftUI content. So measure ONCE at identity and CACHE; the
//  transform then only scales an already-correctly-sized card.

import UIKit

@MainActor
final class CardViewController: UIViewController, UIGestureRecognizerDelegate {
    let surfaceID: UUID
    private let bodyVC: UIViewController
    private let glassHost = UIVisualEffectView()

    /// Raise this surface to the top of the paint order (touch-down / drag begins).
    var onBringToFront: ((UUID) -> Void)?
    /// A decisive sideways flick dismisses the card. (The full app COLLECTS it to a board instead.)
    var onDismiss: ((UUID) -> Void)?

    /// Canvas-driven resting tilt (radians) — a small per-surface rotation for a hand-placed feel.
    var baseTilt: CGFloat = 0
    /// The front card renders at full scale + a stronger shadow; held cards sit back slightly.
    var isFrontCard: Bool = false { didSet { guard isFrontCard != oldValue else { return }; applyShadow() } }
    /// True while the user is dragging this card — the canvas skips re-layout so it doesn't fight the drag.
    private(set) var isInteracting = false

    private static let heldScale: CGFloat = 0.94
    private static let heldAlpha: CGFloat = 0.55
    private var depthScale: CGFloat { isFrontCard ? 1 : Self.heldScale }
    private var depthAlpha: CGFloat { isFrontCard ? 1 : Self.heldAlpha }

    private var panStartCenter: CGPoint = .zero
    private var cachedContentSize: CGSize?
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Resting transform: tilt × held-depth scale (1.0 for the front card). Any lift/bloom scales ON TOP.
    private var restingTransform: CGAffineTransform {
        CGAffineTransform(rotationAngle: baseTilt).scaledBy(x: depthScale, y: depthScale)
    }

    init(surfaceID: UUID, bodyVC: UIViewController) {
        self.surfaceID = surfaceID
        self.bodyVC = bodyVC
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// N4: releases views only — NEVER touches audio / the session (it holds no such reference).
    deinit { }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = true   // frame-positioned by the canvas
        view.layer.shadowColor = UIColor.black.cgColor
        installGlassHost()
        installBody()
        installGestures()
        applyShadow()
    }

    private func applyShadow() {
        view.layer.shadowOpacity = isFrontCard ? 0.22 : 0.10
        view.layer.shadowRadius = isFrontCard ? 22 : 12
        view.layer.shadowOffset = CGSize(width: 0, height: isFrontCard ? 12 : 6)
    }

    private func installGlassHost() {
        glassHost.translatesAutoresizingMaskIntoConstraints = false
        glassHost.effect = nil   // start dematerialized; materialize() animates the glass in
        glassHost.layer.cornerRadius = 20
        glassHost.layer.cornerCurve = .continuous
        glassHost.clipsToBounds = true
        view.addSubview(glassHost)
        pinEdges(glassHost, to: view)
    }

    private func installBody() {
        addChild(bodyVC)
        bodyVC.view.backgroundColor = .clear
        bodyVC.view.translatesAutoresizingMaskIntoConstraints = false
        glassHost.contentView.addSubview(bodyVC.view)
        pinEdges(bodyVC.view, to: glassHost.contentView)
        bodyVC.didMove(toParent: self)
    }

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    // MARK: Sizing (measure transform-free + cache — see the landmine note up top)

    func preferredSize() -> CGSize {
        if let cached = cachedContentSize { return cached }
        let measured = measureContentSize()
        cachedContentSize = measured
        return measured
    }

    private func measureContentSize() -> CGSize {
        let saved = view.transform
        let neutralize = saved != .identity
        if neutralize {
            CATransaction.begin(); CATransaction.setDisableActions(true); view.transform = .identity
        }
        let fitted = view.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        if neutralize { view.transform = saved; CATransaction.commit() }
        return CGSize(width: max(fitted.width, 180), height: max(fitted.height, 56))
    }

    // MARK: Materialize / dematerialize (animate the glass .effect — NEVER alpha)

    func materialize(animated: Bool) {
        view.alpha = depthAlpha
        let glass = Self.makeGlassEffect()
        guard animated, !reduceMotion else { view.transform = restingTransform; glassHost.effect = glass; return }
        view.transform = restingTransform.scaledBy(x: 0.86, y: 0.86)
        UIViewPropertyAnimator(duration: 0.36, dampingRatio: 0.8) {
            self.glassHost.effect = glass
            self.view.transform = self.restingTransform
        }.startAnimation()
    }

    func dematerialize(then completion: @escaping () -> Void) {
        guard !reduceMotion else { glassHost.effect = nil; completion(); return }
        let animator = UIViewPropertyAnimator(duration: 0.28, curve: .easeIn) {
            self.glassHost.effect = nil
            self.view.transform = self.restingTransform.scaledBy(x: 0.82, y: 0.82)
        }
        animator.addCompletion { _ in completion() }
        animator.startAnimation()
    }

    /// iOS 26 Liquid Glass (the deployment target is 26.x → always taken); the blur is a defensive
    /// fallback so the card still reads if this ever ships lower.
    private static func makeGlassEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = false
            return glass
        } else {
            return UIBlurEffect(style: .systemUltraThinMaterial)
        }
    }

    // MARK: Drag (transform / center only — the model is untouched until .ended)

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let parent = view.superview else { return }
        switch g.state {
        case .began:
            isInteracting = true
            panStartCenter = view.center
            onBringToFront?(surfaceID)
            isFrontCard = true
        case .changed:
            let t = g.translation(in: parent)
            view.center = CGPoint(x: panStartCenter.x + t.x, y: panStartCenter.y + t.y)
        case .ended, .cancelled, .failed:
            isInteracting = false
            // MVP: a decisive sideways flick DISMISSES; otherwise settle back. (Full app COLLECTS.)
            let translation = g.translation(in: parent)
            let velocity = g.velocity(in: parent)
            let flick = abs(translation.x) > abs(translation.y) && (abs(velocity.x) > 900 || abs(translation.x) > 160)
            if flick { onDismiss?(surfaceID) } else { animateSettle(to: panStartCenter) }
        default: break
        }
    }

    // MARK: Canvas-driven placement

    func place(restingCenter: CGPoint, animated: Bool) {
        let apply = { self.view.center = restingCenter; self.view.transform = self.restingTransform; self.view.alpha = self.depthAlpha }
        guard animated, !reduceMotion, !isInteracting else { apply(); return }
        UIViewPropertyAnimator(duration: 0.4, dampingRatio: 0.84, animations: apply).startAnimation()
    }

    private func animateSettle(to target: CGPoint) {
        guard !reduceMotion else { view.center = target; view.transform = restingTransform; return }
        UIViewPropertyAnimator(duration: 0.45, dampingRatio: 0.82) {
            self.view.center = target; self.view.transform = self.restingTransform
        }.startAnimation()
    }

    // Pan recognizes alongside the body's own gestures (e.g. a `choice` button tap) so press-then-drag works.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func pinEdges(_ child: UIView, to parent: UIView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}
