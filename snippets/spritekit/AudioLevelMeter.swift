//
//  AudioLevelMeter.swift  (minimal-realtime-kit — REDACTED snippet)
//
//  Lock-guarded RMS meter. Producers (mic buffers, decoded TTS PCM) write OFF the main thread;
//  the render tick reads `level()` once per frame. An attack/release envelope makes the body's
//  pulse swell and decay instead of strobing. This is the bridge between your audio plumbing and
//  the character's `levelProvider`.
//
//  Near-verbatim from `OpenAIRealtimeSample/Engine/AudioLevelMeter.swift` (already clean, key-free).
//  Typical setup: TWO instances — one fed from the user's mic (drives "listening"/inward), one from
//  the agent's TTS PCM (drives "speaking"/outward). Pick which to read by the current turn.
//

import Foundation
import Accelerate
import AVFoundation

public final class AudioLevelMeter: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Float(0))
    private let attack: Float
    private let release: Float
    private let floorDB: Float

    public init(attack: Float = 0.35, release: Float = 0.06, floorDB: Float = -50) {
        self.attack = attack
        self.release = release
        self.floorDB = floorDB
    }

    /// Current smoothed level, 0…1. Safe to call from any thread (read once per frame). (src:31)
    public func level() -> Float { state.withLock { $0 } }

    /// Decay to silence (e.g. when a turn ends). (src:34)
    public func reset() { state.withLock { $0 = 0 } }

    /// Meter raw float samples. (src:36-41)
    public func ingest(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
        apply(rms: rms)
    }

    /// Meter an `AVAudioPCMBuffer` (the mic stream); handles float or int16. (src:44-58)
    public func ingest(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        if let floats = buffer.floatChannelData {
            ingest(floats[0], frameCount: frames)
        } else if let ints = buffer.int16ChannelData {
            let p = ints[0]
            var sum: Float = 0
            for n in 0..<frames {
                let s = Float(p[n]) / 32768.0
                sum += s * s
            }
            apply(rms: (sum / Float(frames)).squareRoot())
        }
    }

    /// Meter base64-encoded PCM16 (e.g. realtime `response.audio.delta` payloads). (src:61-74)
    public func ingestPCM16(base64: String) {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Int16.self)
            let count = buf.count
            guard count > 0 else { return }
            var sum: Float = 0
            for n in 0..<count {
                let s = Float(Int16(littleEndian: buf[n])) / 32768.0
                sum += s * s
            }
            apply(rms: (sum / Float(count)).squareRoot())
        }
    }

    /// dB-normalize to 0…1, then apply the attack/release envelope. (src:76-82)
    private func apply(rms: Float) {
        let db = 20 * log10(max(rms, 1e-7))
        let target = max(0, min(1, (db - floorDB) / -floorDB))
        state.withLock { cur in
            cur += (target - cur) * (target > cur ? attack : release)
        }
    }
}
