// 05-websocket-connect.swift
//
// ILLUSTRATIVE sketch — the dependency-free Realtime transport for a MINIMAL iOS core:
// URLSessionWebSocketTask. This matches AIProxySwift's heritage. You own audio capture/playback
// (AVAudioEngine, 24kHz PCM16 mono) and barge-in truncation yourself.
//
// OpenAI RECOMMENDS WebRTC for client/mobile apps (better media on flaky networks). Use this WS
// path when you want zero extra dependencies and are willing to own audio I/O. See
// 06-webrtc-connect.swift for the recommended path.
//
// Auth: connect with an EPHEMERAL `ek_...` token (mint via 01-mint-ephemeral-client-secret.sh).
// Never embed a standing sk-... key.
//
// Docs: https://platform.openai.com/docs/guides/realtime-conversations

import Foundation

final class MinimalRealtimeWebSocket: NSObject {
    private var task: URLSessionWebSocketTask?
    private let model = "gpt-realtime-2"

    /// `ephemeralKey` is the `value` ("ek_...") returned by /v1/realtime/client_secrets.
    func connect(ephemeralKey: String) {
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        req.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
        // NOTE: GA does NOT use the old beta header `OpenAI-Beta: realtime=v1` (retired 2026-05-07).

        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: req)
        task?.resume()
        receiveLoop()
    }

    /// Drain server events. Route by `type` (session.created, response.output_audio.delta,
    /// response.function_call_arguments.done, response.done, input_audio_buffer.speech_started, ...).
    private func receiveLoop() {
        task?.receive { [weak self] result in
            switch result {
            case .success(.string(let json)):
                self?.handleServerEvent(json)        // parse + dispatch
            case .success(.data(let data)):
                self?.handleServerEvent(String(decoding: data, as: UTF8.self))
            case .success(let other):
                print("unexpected ws message: \(other)")
            case .failure(let error):
                print("ws error (GA halts the receive loop on error — reconnect): \(error)")
                return                                // stop looping; trigger reconnect upstream
            }
            self?.receiveLoop()
        }
    }

    private func handleServerEvent(_ json: String) { /* decode JSON, switch on "type" */ }

    func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { if let e = $0 { print("send error: \(e)") } }
    }

    // --- Audio (you implement with AVAudioEngine) ---
    // Input:  base64-encode 24kHz PCM16 mono chunks -> send {"type":"input_audio_buffer.append","audio": base64}
    //         (with VAD enabled, the server auto-commits + responds; otherwise commit + response.create yourself)
    // Output: listen for {"type":"response.output_audio.delta","delta": base64} -> decode + play
    // Barge-in: on input_audio_buffer.speech_started, stop playback and send conversation.item.truncate
}
