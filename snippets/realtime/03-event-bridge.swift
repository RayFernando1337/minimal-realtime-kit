//
//  03-event-bridge.swift  —  REDACTED extract for minimal-realtime-kit
//
//  The actor↔UI bridge: a `nonisolated AsyncStream<PebblesEvent>` produced on the
//  @AIProxyActor manager and drained on a single @MainActor @Observable model.
//
//  Sources:
//   • enum PebblesEvent / PebblesState / PebblesTone — Pebbles/PebblesState.swift:13-105
//   • drainer + apply(_:)                            — Conversation/ConversationModel.swift:159-351
//

import SwiftUI

// MARK: - State the orb renders. Source: PebblesState.swift:13-20
nonisolated enum PebblesState: Equatable, Sendable {
    case dormant      // no live session
    case connecting   // session starting
    case idle         // session live, between turns
    case listening    // user is speaking (energy flows INWARD)
    case thinking     // a response is forming, before audio
    case searching    // the web_search tool is running
    case speaking     // Pebbles is talking (energy flows OUTWARD)
}

// Pebbles' emotional read of *you*. Source: PebblesState.swift:80-82
nonisolated enum PebblesTone: Equatable, Sendable {
    case neutral, warm, concerned, playful
}

// MARK: - The event contract. Source: PebblesState.swift:86-105
// Sendable so it can cross the actor boundary via AsyncStream.
nonisolated enum PebblesEvent: Sendable {
    case state(PebblesState)                  // → drives liveState; clears transcripts on listen/think
    case tone(PebblesTone)                    // → tone (NOTE: manager never emits this; see below)
    case userTranscriptDelta(String)          // → append to userText
    case userTranscriptFinal(String)          // → set userText, record history, infer tone
    case pebblesTranscriptDelta(String)       // → append to pebblesText
    case pebblesTranscriptFinal(String)       // → set pebblesText, record history
    case note(PostItContent)                  // → surface a UI card (surface_note / search answer)
    case component(ComponentRequest?)         // → render an agent-selected component; nil ⇒ fallback
    case memoryChanged                        // → live-refresh memory-backed UI
    case error(String)                        // → go dormant
}
//  ⚠️ Emission asymmetry (confidence: high): the MANAGER only ever yields
//  .state, .error, .note, .component, .memoryChanged, and the 4 transcript cases.
//  It NEVER yields .tone — tone is computed LOCALLY on the MainActor from user finals
//  (see inferTone below). For an MVP you can delete the .tone case + ToneInference.

@MainActor
@Observable
final class ConversationModel {
    private let manager: RealtimeManager
    private var eventTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    private var liveState: PebblesState = .dormant
    var state: PebblesState { liveState }
    private(set) var tone: PebblesTone = .neutral
    private(set) var userText: String = ""
    private(set) var pebblesText: String = ""

    /// The latest card the live session asked the stage to surface. A view observes this.
    private(set) var noteRequest: NoteRequest?
    struct NoteRequest: Equatable { let id = UUID(); let content: PostItContent }

    var isActive: Bool { state != .dormant }

    // MARK: - The SOLE drainer. Source: ConversationModel.swift:182-192
    init() {
        let mgr = RealtimeManager()
        manager = mgr
        // ONE consumer of the event stream, for the whole app lifetime.
        eventTask = Task { [weak self] in
            for await event in mgr.events {
                self?.apply(event)
            }
        }
    }

    // MARK: - Levels (read per render frame by the orb). Source: ConversationModel.swift:241-247
    func currentLevel() -> Float {
        switch state {
        case .listening: manager.micMeter.level()
        case .speaking:  manager.pebblesMeter.level()
        default:         0
        }
    }

    // MARK: - Control. Source: ConversationModel.swift:264-315 (trimmed)
    func toggle() { isActive ? stop() : start() }

    func start() {
        guard liveState == .dormant else { return }
        liveState = .connecting
        runTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.manager.startConversation() }
            catch { self.liveState = .dormant }
        }
    }

    func stop() {
        runTask?.cancel(); runTask = nil
        let mgr = manager
        Task { await mgr.stopConversation() }
        withAnimation(.easeInOut) { liveState = .dormant }
        userText = ""; pebblesText = ""
    }

    // MARK: - The map: each event case → @Observable mutation. Source: ConversationModel.swift:319-351
    private func apply(_ event: PebblesEvent) {
        switch event {
        case .state(let next):
            if next == .listening { userText = "" }
            if next == .thinking  { pebblesText = "" }
            withAnimation(.easeInOut) { liveState = next }
        case .note(let content):
            noteRequest = NoteRequest(content: content)
        case .component(let request):
            renderComponentRequest(request)          // factory worker owns this
        case .memoryChanged:
            break                                    // bump a revision counter in the full app
        case .tone(let next):
            withAnimation(.easeInOut) { tone = next }
        case .userTranscriptDelta(let delta):
            userText += delta
        case .userTranscriptFinal(let text):
            userText = text
            inferTone(fromUserText: text)            // local tone read (optional for MVP)
        case .pebblesTranscriptDelta(let delta):
            pebblesText += delta
        case .pebblesTranscriptFinal(let text):
            pebblesText = text
        case .error:
            withAnimation(.easeInOut) { liveState = .dormant }
        }
    }

    // Tone is inferred LOCALLY here, not sent by the manager. Source: ConversationModel.swift:430-436
    private func inferTone(fromUserText text: String) {
        let inferred = ToneInference.tone(forUserText: text)
        guard inferred != .neutral else { return }
        withAnimation(.easeInOut) { tone = inferred }
        // (full app also arms a decay task back to .neutral — ConversationModel.swift:441-449)
    }

    // Placeholder — the factory worker (02-factory-pattern) owns the real implementation.
    private func renderComponentRequest(_ request: ComponentRequest?) { /* … */ }
}
