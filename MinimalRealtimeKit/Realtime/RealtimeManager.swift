//  RealtimeManager.swift
//  T1.2 — the realtime session lifecycle, on the @AIProxyActor global actor.
//
//  Golden lifecycle: connect → GA session config → mic loop → receiver loop → state
//  emission → generation-guarded stop. Audio + session are OWNED here, never by a
//  view/VC (SPEC N4). The actor exposes ONE `nonisolated` event stream that a single
//  @MainActor model drains (SPEC N5); the two meters are read per-frame, off
//  observation, by the character (SPEC N6).
//
//  Adapted from snippets/realtime/01-lifecycle.swift to the confirmed AIProxySwift
//  0.153.0 API in BYO-key DIRECT mode. The OpenAI key is resolved ONLY from the
//  Keychain through the Tier-0 `RealtimeCredentialProvider` seam — never hardcoded,
//  never logged (SPEC N1). There is exactly ONE response.create send in this file: the
//  greeting (SPEC N2); tools (and their sends) arrive in Tier 2.

import AIProxy
import AVFoundation

@AIProxyActor
final class RealtimeManager {
    // MARK: - Injected dependencies (all Sendable; default to the v1 paste-key path)
    private let provider: RealtimeCredentialProvider
    private let personality: Personality
    /// Fulfills `web_search` (a deferred CLIENT tool — NOT the SDK's hosted `.webSearch`).
    /// Defaults to `ExaWebSearchProvider`, which reads a BYO EXA key from the Keychain per call
    /// and returns a graceful "unconfigured" envelope when none is stored (so the kit still runs
    /// key-free). Inject another provider to swap services. Internal so the tool-dispatch
    /// extension can reach it. (SPEC N1: the key lives in the Keychain, never here.)
    let webSearch: WebSearchProvider

    // MARK: - Live session + audio (owned here — N4; a view/VC must never touch these)
    // `realtimeSession` is internal (not private) so the tool-dispatch extension in
    // RealtimeManager+Tools.swift can reach it (sendUserChoice / sendContextUpdate).
    var realtimeSession: OpenAIRealtimeSession?
    private var audioController: AudioController?

    // MARK: - UI bridge (N5) — `nonisolated` so the @MainActor drainer reads without hopping
    nonisolated let events: AsyncStream<PebblesEvent>
    nonisolated private let eventContinuation: AsyncStream<PebblesEvent>.Continuation
    nonisolated let micMeter = AudioLevelMeter()      // "listening" energy (N6)
    nonisolated let pebblesMeter = AudioLevelMeter()  // "speaking" energy (N6)

    // MARK: - Turn / lifecycle bookkeeping
    private var lastState: PebblesState?
    private var muted = false
    /// True between a send and `.responseDone`/`.error`. Set BEFORE every send so the
    /// pre-round-trip window can't double-fire alongside server-VAD's auto-response. Internal
    /// (not private) so the tool-dispatch extension sets it before its sends (SPEC N2).
    var responseInFlight = false
    /// "Stop always wins" guard: bumped before any `await` (and on stop). Every gate compares
    /// to a per-connect snapshot, so a superseded connect tears itself down instead of greeting.
    private var sessionGeneration = 0
    /// Gates outgoing mic frames until the model is ready to receive them.
    private var isOpenAIReadyForAudio = false

    nonisolated init(
        provider: RealtimeCredentialProvider = PastedKeyProvider(),
        personality: Personality = .default,
        webSearch: WebSearchProvider = ExaWebSearchProvider()
    ) {
        self.provider = provider
        self.personality = personality
        self.webSearch = webSearch
        (events, eventContinuation) = AsyncStream.makeStream(of: PebblesEvent.self)
    }

    // MARK: - Emit helpers

    // `emit`/`emitState` are internal (not private) so the tool-dispatch extension can surface
    // tool-driven UI events (the `.searching` state, and Tier-4 cards). One stream still, one
    // drainer (SPEC N5) — these just yield onto it.
    func emit(_ event: PebblesEvent) { eventContinuation.yield(event) }

    /// Emit a state only when it actually changes — audio deltas fire ~50/s, so re-emitting the
    /// same state would spam the drainer.
    func emitState(_ state: PebblesState) {
        guard state != lastState else { return }
        lastState = state
        eventContinuation.yield(.state(state))
    }

    // MARK: - Mute (withholds OUTGOING mic frames only; the session stays fully live)

    func setMuted(_ on: Bool) {
        guard muted != on else { return }
        muted = on
        if on { micMeter.reset() }
    }

    // MARK: - Connect → configure → stream → receive

    func startConversation() async throws {
        // Bump the generation BEFORE any await and snapshot our copy. A later stop()/reconnect
        // bumps it again; every gate below compares to this snapshot so a superseded connect
        // bails (and never leaks a second VoiceProcessingIO unit).
        sessionGeneration += 1
        let myGeneration = sessionGeneration
        self.muted = false
        self.isOpenAIReadyForAudio = false
        self.responseInFlight = false
        emitState(.connecting)

        // N1: resolve the key ONLY from the Keychain via the provider seam. If nothing is stored
        // (`PastedKeyProvider.ProviderError.noKeyStored`), go dormant and rethrow so the UI can
        // prompt the user to paste their key.
        let cred: RealtimeCredential
        do {
            cred = try await provider.credential()
        } catch {
            emitState(.dormant)
            throw error
        }

        // D1: the BYO-key DIRECT path (NOT the proxy key-splitting service path).
        let service = AIProxy.openAIDirectService(unprotectedAPIKey: cred.token)

        let aiSpeaksFirst = true
        let allowBargeIn = true

        // Cheap VPIO win: if a stop already superseded us, bail before building any audio unit.
        if Task.isCancelled || myGeneration != sessionGeneration {
            emitState(.dormant)
            return
        }

        // ONE VoiceProcessingIO unit. Overlapping units crash the SDK mic vendor; the generation
        // gates plus stop()'s teardown ordering keep it to a single unit at a time.
        let audioController = try await AudioController(
            modes: [.playback, .record],
            useManualEchoCancellation: allowBargeIn
        )
        let micStream = try audioController.micStream()

        // GA realtime session config — flat params; the SDK encodes the nested GA wire internally.
        // Tier 2 wires the tool catalog (`Self.agentTools`) + a persona-with-tools prompt
        // (`Self.instructions`); the tools are dispatched in RealtimeManager+Tools.swift under N2.
        let configuration = OpenAIRealtimeSessionConfiguration(
            inputAudioFormat: .pcm16,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe"),
            instructions: Self.instructions(personality: personality),
            maxResponseOutputTokens: .int(4096),
            outputModalities: [.audio],
            outputAudioFormat: .pcm16,
            tools: Self.agentTools,
            toolChoice: .auto,
            // Semantic VAD with createResponse:true ⇒ the SERVER auto-fires a response for a
            // spoken user turn; interruptResponse enables barge-in.
            turnDetection: .semanticVAD(
                .init(createResponse: true, eagerness: .auto, interruptResponse: allowBargeIn)
            ),
            voice: .builtin(personality.voiceName)
        )

        let realtimeSession = try await service.realtimeSession(
            model: "gpt-realtime-2",
            configuration: configuration,
            logLevel: .info
        )

        // We suspended at the audio + session awaits; if a stop/reconnect interleaved, drop what
        // we built instead of leaking a live VPIO render thread.
        if Task.isCancelled || myGeneration != sessionGeneration {
            audioController.stop()
            realtimeSession.disconnect()
            emitState(.dormant)
            return
        }

        // ── Mic → OpenAI ───────────────────────────────────────────────────────────────────
        // Inherits this actor's isolation; ends naturally when audioController.stop() finishes
        // the mic stream. Each frame meters the orb (N6), then (when ready) ships as PCM16.
        Task {
            for await buffer in micStream {
                if self.muted { continue }
                self.micMeter.ingest(buffer: buffer)
                if self.isOpenAIReadyForAudio,
                   let base64Audio = AIProxy.base64EncodeAudioPCMBuffer(from: buffer) {
                    await realtimeSession.sendMessage(
                        OpenAIRealtimeInputAudioBufferAppend(audio: base64Audio)
                    )
                }
            }
        }

        // ── Receiver loop: server events → discrete state + transcripts ──────────────────────
        // `.receiver` is accessed EXACTLY ONCE (N5). A superseded session self-terminates.
        Task {
            for await message in realtimeSession.receiver {
                guard myGeneration == self.sessionGeneration else {
                    realtimeSession.disconnect()
                    break
                }
                switch message {
                case .error:
                    // The SDK halts its OWN receive loop on ANY error event, so the session is a
                    // zombie afterward; MVP recovery is simply to go dormant (auto-reconnect is a
                    // documented Tier-5 add).
                    self.responseInFlight = false
                    self.emit(.error("The session hit an error."))
                    self.emitState(.dormant)
                    realtimeSession.disconnect()

                case .sessionUpdated:
                    self.emitState(.idle)
                    if aiSpeaksFirst {
                        // ── The ONE response.create site in this file (N2): the GREETING. ──
                        // responseInFlight is set BEFORE the send (pairs with server-VAD).
                        self.responseInFlight = true
                        await realtimeSession.sendMessage(OpenAIRealtimeResponseCreate())
                    } else {
                        self.isOpenAIReadyForAudio = true
                    }

                case .responseCreated:
                    self.responseInFlight = true
                    self.emitState(.thinking)
                    self.isOpenAIReadyForAudio = allowBargeIn

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
                    if allowBargeIn { audioController.interruptPlayback() }

                case .responseFunctionCallArgumentsDone(let event):
                    // Tier 2 dispatch. web_search is slow → show `.searching` while it runs
                    // (handleFunctionCall returns immediately for it; the work runs off-loop).
                    if event.name == "web_search" { self.emitState(.searching) }
                    await self.handleFunctionCall(event, session: realtimeSession)

                case .responseDone:
                    self.responseInFlight = false
                    self.emitState(.idle)
                    self.pebblesMeter.reset()
                    self.isOpenAIReadyForAudio = true

                default:
                    break
                }
            }
        }

        // Final gate before publishing — last chance to bail if a stop interleaved mid-spawn.
        guard myGeneration == sessionGeneration else {
            audioController.stop()
            realtimeSession.disconnect()
            emitState(.dormant)
            return
        }
        self.realtimeSession = realtimeSession
        self.audioController = audioController
    }

    // MARK: - Stop (always wins)

    func stopConversation() {
        self.audioController?.stop()
        self.realtimeSession?.disconnect()
        self.audioController = nil
        self.realtimeSession = nil
        self.micMeter.reset()
        self.pebblesMeter.reset()
        // Bump so any in-flight connect bails before assigning/greeting and stale loops
        // self-terminate on their generation guard.
        self.sessionGeneration += 1
        self.responseInFlight = false
        self.isOpenAIReadyForAudio = false
        self.emitState(.dormant)
    }
}
