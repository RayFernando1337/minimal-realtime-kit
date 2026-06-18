//  AudioLevelMeter.swift
//  T1.1/T1.2 — a lock-guarded RMS meter with an attack/release envelope.
//
//  Two instances run on the manager:
//   • micMeter     — fed AVAudioPCMBuffers from the mic        → drives "listening" energy
//   • pebblesMeter — fed base64 PCM16 from responseAudioDelta  → drives "speaking" energy
//  Producers write off the main thread; the render tick reads `level()` once per frame
//  (SPEC N6 — the level never goes through observation). Dependency-free beyond
//  Accelerate/AVFoundation/os, so it is lifted as-is from snippets/realtime/06.

import Foundation
import Accelerate
import AVFoundation
import os

nonisolated final class AudioLevelMeter: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Float(0))
    private let attack: Float
    private let release: Float
    private let floorDB: Float

    init(attack: Float = 0.35, release: Float = 0.06, floorDB: Float = -50) {
        self.attack = attack
        self.release = release
        self.floorDB = floorDB
    }

    /// Current smoothed level, 0...1. Safe to call from any thread (read per frame).
    func level() -> Float { state.withLock { $0 } }

    /// Decay to silence (e.g., when a turn ends).
    func reset() { state.withLock { $0 = 0 } }

    func ingest(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
        apply(rms: rms)
    }

    /// Meter an `AVAudioPCMBuffer` (the mic stream). Handles float or int16 data.
    func ingest(buffer: AVAudioPCMBuffer) {
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

    /// Meter base64-encoded PCM16 (the `responseAudioDelta` payloads).
    func ingestPCM16(base64: String) {
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

    private func apply(rms: Float) {
        let db = 20 * log10(max(rms, 1e-7))
        let target = max(0, min(1, (db - floorDB) / -floorDB))
        state.withLock { cur in
            cur += (target - cur) * (target > cur ? attack : release)
        }
    }
}
