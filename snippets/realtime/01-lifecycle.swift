//
//  01-lifecycle.swift  —  REDACTED extract for minimal-realtime-kit
//
//  Source: OpenAIRealtimeSample/RealtimeManager.swift  (lines cited inline below).
//  This is an MVP-trimmed, REDACTED copy: the park/collect/dismiss/memory/consult/
//  TurnTrace branches are removed to show the *golden lifecycle*. Real AIProxy keys
//  + service URLs have been replaced with <<PASTE_YOUR_OWN>>.
//
//  Lifecycle = connect → session config → mic streaming → receiver loop →
//              state emission → stop.
//
//  SDK: AIProxySwift (import AIProxy). Swap the AIProxy.* calls for a raw
//  URLSession WebSocket if you want a zero-dependency BYOK build (see research doc §AIProxy surface).
//

import AIProxy
import AVFoundation
import os

// The manager runs on the SDK's global actor so the receiver loop, the mic loop, and
// the send sites all share one executor (no locks). Source: RealtimeManager.swift:22
@AIProxyActor final class RealtimeManager {
    private var realtimeSession: OpenAIRealtimeSession?
    private var audioController: AudioController?

    // MARK: - UI bridge (see 03-event-bridge.swift)
    // `nonisolated` so the @MainActor drainer can read it without hopping the actor.
    // Source: RealtimeManager.swift:32-36, 130
    nonisolated let events: AsyncStream<PebblesEvent>
    nonisolated private let eventContinuation: AsyncStream<PebblesEvent>.Continuation
    nonisolated let micMeter = AudioLevelMeter()      // drives "listening" energy
    nonisolated let pebblesMeter = AudioLevelMeter()  // drives "speaking" energy

    private var lastState: PebblesState?
    private var muted = false

    // Turn-guard: true between `.responseCreated` and `.responseDone`/`.error`. Set BEFORE
    // every send (FIX C) so the pre-round-trip window can't double-fire a response.create.
    // Source: RealtimeManager.swift:79
    private var responseInFlight = false

    // "stop always wins" generation guard. Source: RealtimeManager.swift:95
    private var sessionGeneration = 0

    nonisolated init() {
        (events, eventContinuation) = AsyncStream.makeStream(of: PebblesEvent.self)
    }

    private func emit(_ event: PebblesEvent) { eventContinuation.yield(event) }

    /// Emit a state change only when it actually changes (audio deltas fire ~50/s).
    /// Source: RealtimeManager.swift:145-149
    private func emitState(_ state: PebblesState) {
        guard state != lastState else { return }
        lastState = state
        eventContinuation.yield(.state(state))
    }

    func setMuted(_ on: Bool) {
        guard muted != on else { return }
        muted = on
        if on { micMeter.reset() }
    }

    // MARK: - Connect / configure / stream / receive
    // Source: RealtimeManager.swift:151-409 (trimmed)
    func startConversation(personality: Personality = Personalities.pebbles) async throws {
        // Bump the generation up front (before any await) and snapshot OUR copy. A later
        // stop()/reconnect bumps it again; every gate below compares to this snapshot so a
        // superseded connect tears itself down instead of greeting. Source: :162-163
        sessionGeneration += 1
        let myGeneration = sessionGeneration
        self.muted = false
        emitState(.connecting)

        // ⬇️ BYOK / proxy credentials. NEVER commit real values. Source: :182-183 (REDACTED)
        let aiproxyPartialKey = "<<PASTE_YOUR_OWN>>"
        let aiproxyServiceURL = "<<PASTE_YOUR_OWN>>"
        let openAIService = AIProxy.openAIService(
            partialKey: aiproxyPartialKey,
            serviceURL: aiproxyServiceURL
        )
        // BYOK-direct alternative (don't ship in a real app). Source: :194-195
        // let openAIService = AIProxy.openAIDirectService(unprotectedAPIKey: "<<PASTE_YOUR_OWN>>")

        let aiSpeaksFirst = true        // Source: :198
        let allowBargeIn  = true        // Source: :199-202

        // Audio: ONE VoiceProcessingIO unit. Overlapping units crash the SDK mic vendor —
        // see stop()/teardown ordering. Source: :204-208
        let audioController = try await AudioController(
            modes: [.playback, .record],
            useManualEchoCancellation: allowBargeIn
        )
        let micStream = try audioController.micStream()

        // GA Realtime session config. Source: :229-264
        let configuration = OpenAIRealtimeSessionConfiguration(
            inputAudioFormat: .pcm16,
            // Async transcription of the user's mic (display/logging only), separate from the
            // speech-to-speech model.
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe"),
            instructions: Self.instructions(personality: personality),
            maxResponseOutputTokens: .int(4096),
            outputModalities: [.audio],
            outputAudioFormat: .pcm16,
            tools: Self.agentTools,                 // see 04-tool-schemas.swift
            toolChoice: .auto,
            // Semantic VAD with createResponse:true ⇒ the SERVER auto-fires a response for a
            // spoken user turn. `interruptResponse` enables barge-in. Source: :253-259
            turnDetection: .semanticVAD(
                .init(createResponse: true, eagerness: .auto, interruptResponse: allowBargeIn)
            ),
            voice: .builtin(personality.voiceName)  // "cedar" / "marin" on gpt-realtime-2
        )

        // ⚠️ Confirm the latest GA model string via live docs before shipping (worker F).
        // Source: :266-270
        let realtimeSession = try await openAIService.realtimeSession(
            model: "gpt-realtime-2",
            configuration: configuration,
            logLevel: .debug
        )

        // We had await suspension points above, so stop() could have interleaved. If a stop/
        // reconnect superseded us, drop what we built instead of leaking a live VPIO thread.
        // Source: :280-285
        if Task.isCancelled || myGeneration != sessionGeneration {
            audioController.stop()
            realtimeSession.disconnect()
            emitState(.dormant)
            return
        }

        // ── Mic → OpenAI. Source: :288-300 ──────────────────────────────────────────
        var isOpenAIReadyForAudio = false
        Task {
            for await buffer in micStream {
                if self.muted { continue }
                self.micMeter.ingest(buffer: buffer)   // meter for the orb's listening pulse
                if isOpenAIReadyForAudio,
                   let base64Audio = AIProxy.base64EncodeAudioPCMBuffer(from: buffer) {
                    await realtimeSession.sendMessage(
                        OpenAIRealtimeInputAudioBufferAppend(audio: base64Audio)
                    )
                }
            }
        }

        // ── Receiver loop: server events → state + transcripts + tool calls. Source: :303-397 ──
        Task {
            for await message in realtimeSession.receiver {
                // A superseded/stopped session self-terminates. Source: :307
                guard myGeneration == self.sessionGeneration else {
                    realtimeSession.disconnect(); break
                }
                switch message {
                case .error(let errorEvent):
                    // The SDK halts its OWN receive loop on ANY error event — recovery needs a
                    // reconnect (see research §lifecycle hardening). MVP: just go dormant.
                    self.responseInFlight = false
                    self.emit(.error("The session hit an error."))
                    self.emitState(.dormant)
                    realtimeSession.disconnect()

                case .sessionUpdated:
                    self.emitState(.idle)
                    if aiSpeaksFirst {
                        // ── response.create SITE 1 of 4: GREETING ──
                        self.responseInFlight = true   // FIX C: set BEFORE the send. Source: :332
                        await realtimeSession.sendMessage(OpenAIRealtimeResponseCreate())
                    } else {
                        isOpenAIReadyForAudio = true
                    }

                case .responseAudioDelta(let event):
                    self.emitState(.speaking)
                    self.pebblesMeter.ingestPCM16(base64: event.base64Audio)
                    audioController.playPCM16Audio(base64String: event.base64Audio)

                case .responseTranscriptDelta(let event):
                    self.emit(.pebblesTranscriptDelta(event.delta))
                case .responseTranscriptDone(let event):
                    self.emit(.pebblesTranscriptFinal(event.transcript))
                case .inputAudioTranscriptionDelta(let event):
                    if let delta = event.delta { self.emit(.userTranscriptDelta(delta)) }
                case .inputAudioTranscriptionCompleted(let event):
                    self.emit(.userTranscriptFinal(event.transcript))

                case .inputAudioBufferSpeechStarted:
                    self.emitState(.listening)
                    if allowBargeIn { audioController.interruptPlayback() }  // Source: :366-368

                case .responseFunctionCallArgumentsDone(let event):
                    if event.name == "web_search" { self.emitState(.searching) }
                    await self.handleFunctionCall(event, session: realtimeSession)  // 02-tool-dispatch

                case .responseCreated:
                    self.responseInFlight = true
                    self.emitState(.thinking)
                    isOpenAIReadyForAudio = allowBargeIn   // Source: :379

                case .responseDone:
                    self.responseInFlight = false
                    self.emitState(.idle)
                    self.pebblesMeter.reset()
                    isOpenAIReadyForAudio = true

                default:
                    break
                }
            }
        }

        // Last gate before publishing the session. Source: :399-408
        guard myGeneration == sessionGeneration else {
            audioController.stop()
            realtimeSession.disconnect()
            emitState(.dormant)
            return
        }
        self.realtimeSession = realtimeSession
        self.audioController = audioController
    }

    // Source: RealtimeManager.swift:411-440 (trimmed)
    func stopConversation() {
        self.audioController?.stop()
        self.realtimeSession?.disconnect()
        self.audioController = nil
        self.realtimeSession = nil
        self.micMeter.reset()
        self.pebblesMeter.reset()
        // An explicit stop must always WIN: bump the generation so an in-flight connect bails
        // before assigning/greeting, and any stale receiver loop self-terminates. Source: :432
        self.sessionGeneration += 1
        self.responseInFlight = false
        self.emitState(.dormant)
    }

    // handleFunctionCall / completeDeferredToolTurn / sendUserChoice → see 02-tool-dispatch.swift
    // agentTools / instructions → see 04-tool-schemas.swift
}
