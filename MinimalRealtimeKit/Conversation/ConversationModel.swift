//  ConversationModel.swift
//  T1.3 — the @MainActor bridge between the realtime actor and the SwiftUI screen.
//
//  This is the SOLE drainer of `RealtimeManager.events` (SPEC N5): one long-lived
//  `eventTask` consumes the `nonisolated AsyncStream<PebblesEvent>` and maps each of the
//  six v1 events to an @Observable mutation the screen reads. The model OWNS the manager
//  (SPEC N4) — a view/card only calls start()/stop()/setMuted(); nothing in the view layer
//  ever touches audio or the session, and no `deinit` here tears audio down. The continuous
//  audio level is pulled per-frame through `currentLevel()`, deliberately OFF observation
//  (SPEC N6). No key is ever read or logged here (SPEC N1) — the manager resolves it from
//  the Keychain behind the `RealtimeCredentialProvider` seam. This file adds NO
//  `response.create` (SPEC N2): it only asks the manager to start/stop.

import SwiftUI

@MainActor
@Observable
final class ConversationModel {
    // MARK: - Owned realtime stack (N4: the model owns this, never a view/VC)
    private let manager: RealtimeManager
    /// The ONE consumer of the event stream (N5).
    private var eventTask: Task<Void, Never>?
    /// The current connect attempt; cancelled by stop() so "stop always wins".
    private var runTask: Task<Void, Never>?

    // MARK: - Observable UI state (the discrete channel; N6 keeps the level OUT of here)
    /// Discrete lifecycle state, animated for the UI.
    private(set) var state: PebblesState = .dormant
    /// Live transcript of what the user is saying ("You").
    private(set) var userText: String = ""
    /// Live transcript of what the agent is saying ("Agent").
    private(set) var pebblesText: String = ""
    /// Mirrors whether outgoing mic frames are withheld; the toggle is enabled only while active.
    private(set) var isMuted: Bool = false
    /// Mirrors `KeychainStore.hasValue()`; refreshed when the key-entry sheet dismisses.
    private(set) var hasKey: Bool = KeychainStore.hasValue()
    /// A short, user-facing status/error line. NEVER contains any key material (N1).
    private(set) var hint: String?
    /// Set when a start() attempt finds no stored key, so the screen can present key entry.
    private(set) var needsKey: Bool = false

    /// True whenever a session is live (anything but dormant).
    var isActive: Bool { state != .dormant }

    // MARK: - N6 — a non-observed mirror of `state` for the per-frame level path.
    // `currentLevel()` is called ~50×/s from the SpriteKit update loop in a later tier; it
    // must never read observed storage. This copy keeps that hot path entirely off observation.
    @ObservationIgnored private var levelState: PebblesState = .dormant

    // MARK: - Router seam to the card surface (Tier 4; set by the stage, never imported here)
    /// Wired by `StageViewController` to `SurfaceStore.present(request:)`. A clean inversion of
    /// control: a `render_component` event arrives here as `.component`, and the model forwards it to
    /// the canvas without ever knowing about the store. `@ObservationIgnored` — it's a one-time wiring
    /// closure, not UI state.
    @ObservationIgnored var componentSurfaceRouter: ((ComponentRequest?) -> Void)?

    // MARK: - Init: start the ONE event drainer (N5)
    init() {
        let mgr = RealtimeManager()
        manager = mgr
        // The single, long-lived consumer of the event stream for the whole app lifetime.
        eventTask = Task { [weak self] in
            for await event in mgr.events {
                self?.apply(event)
            }
        }
    }

    // MARK: - Per-frame audio level (N6: read directly off the meters, never via observation)
    func currentLevel() -> Float {
        switch levelState {
        case .listening: return manager.micMeter.level()
        case .speaking:  return manager.pebblesMeter.level()
        default:         return 0
        }
    }

    // MARK: - Key status (BYO-key; the model only ever asks "is one stored?", never reads it)
    func refreshHasKey() {
        hasKey = KeychainStore.hasValue()
        if hasKey {
            needsKey = false
            if hint != nil { hint = nil }
        }
    }

    // MARK: - Control surface (the view calls these; the model owns the manager — N4)
    func toggle() { isActive ? stop() : start() }

    func start() {
        guard state == .dormant else { return }
        hint = nil
        needsKey = false
        isMuted = false
        setState(.connecting)
        let mgr = manager
        runTask = Task { [weak self] in
            do {
                try await mgr.startConversation()
            } catch {
                guard let self else { return }
                self.setState(.dormant)
                self.refreshHasKey()
                if let providerError = error as? PastedKeyProvider.ProviderError,
                   providerError == .noKeyStored {
                    self.needsKey = true
                    self.hint = "Add your OpenAI API key, then tap Connect."
                } else {
                    self.hint = "Couldn't start the session. Check your key and try again."
                }
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        let mgr = manager
        Task { await mgr.stopConversation() }
        setState(.dormant)
        userText = ""
        pebblesText = ""
        isMuted = false
    }

    func setMuted(_ on: Bool) {
        isMuted = on
        let mgr = manager
        Task { await mgr.setMuted(on) }
    }

    /// An interactive `choice` card tap is a NEW USER TURN — NOT a second response on the
    /// render_component turn (that would break N2's one-response-per-turn invariant). It forwards to
    /// the manager's `sendUserChoice` (response.create SITE 2 of 4); this method adds none of its own.
    func sendUserChoice(_ text: String) {
        let mgr = manager
        Task { await mgr.sendUserChoice(text) }
    }

    // MARK: - The drainer map: each of the 6 v1 events → an @Observable mutation
    private func apply(_ event: PebblesEvent) {
        switch event {
        case .state(let next):
            // Clear the stale half of the captions as the turn flips.
            if next == .listening { userText = "" }
            if next == .thinking  { pebblesText = "" }
            setState(next)
        case .userTranscriptDelta(let delta):
            userText += delta
        case .userTranscriptFinal(let text):
            userText = text
        case .pebblesTranscriptDelta(let delta):
            pebblesText += delta
        case .pebblesTranscriptFinal(let text):
            pebblesText = text
        case .error(let message):
            hint = message
            setState(.dormant)
        case .component(let request):
            // Route the model-selected card to the canvas (via the stage-wired seam). A nil request
            // (malformed tool call) still flows so the canvas shows the mandatory fallback (N3).
            componentSurfaceRouter?(request)
        }
    }

    // MARK: - Single state setter: animates the observed value AND keeps the N6 mirror in sync.
    private func setState(_ next: PebblesState) {
        levelState = next
        withAnimation(.easeInOut(duration: 0.25)) { state = next }
    }
}
