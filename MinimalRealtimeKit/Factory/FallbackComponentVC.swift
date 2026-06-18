//  FallbackComponentVC.swift
//  T4.1 — the MANDATORY fallback (N3).
//
//  Whatever goes wrong — an unknown / unregistered component id, a payload a builder can't
//  decode, or a malformed tool call — the `ComponentFactory` returns ONE of these instead of
//  crashing or wedging the UI. It logs WHY (telemetry) on init and renders a tiny "couldn't
//  show that" card.
//
//  This is the single guarantee that lets the agent select freely: the worst case is always a
//  small, safe card — never a crash, never a blank/broken surface. Uses system colors + SF
//  Symbols only (no app design tokens) so it renders consistently anywhere.

import UIKit
import os

@MainActor final class FallbackComponentVC: UIViewController {
    /// Why the fallback was shown. Carried for telemetry/debugging; `badPayload` keeps the
    /// underlying decode error so logs explain the exact mismatch.
    enum Reason {
        case unknownID(String)
        case badPayload(String, Error)
        case malformedToolCall
    }

    let reason: Reason

    init(reason: Reason) {
        self.reason = reason
        super.init(nibName: nil, bundle: nil)
        // Telemetry: every fallback is a signal worth seeing. `.public` so it's readable in
        // the unified log (a reliable headless capture channel when print is flaky).
        Logger.componentFactory.error("Component fallback shown: \(Self.describe(reason), privacy: .public)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous

        let icon = UIImageView(image: UIImage(systemName: "questionmark.circle"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Couldn’t show that"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6

        card.addSubview(stack)
        view.addSubview(card)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            // CRITICAL: pin the card to the root view so the VC self-sizes from the card's
            // content. The host/canvas measures this VC; the fallback must NEVER collapse to
            // an invisible 0×0 surface (an invisible fallback = a silently-dropped card).
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// A short, greppable description of the reason — used in telemetry and the DEBUG probe so
    /// fallback coverage is provable without a live backend.
    static func describe(_ reason: Reason) -> String {
        switch reason {
        case .unknownID(let id): return "unknownID(\(id))"
        case .badPayload(let id, let error): return "badPayload(\(id): \(error))"
        case .malformedToolCall: return "malformedToolCall"
        }
    }
}
