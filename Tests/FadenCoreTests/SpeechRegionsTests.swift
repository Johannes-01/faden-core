import Foundation
import Testing
@testable import FadenCore

struct SpeechRegionsTests {
    private let rate = 16_000

    /// Deterministic uniform noise in `-amplitude...amplitude` (RMS ≈ amplitude / √3).
    private struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next(_ amplitude: Float) -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private enum Part {
        case noise(seconds: Double)
        /// A 220 Hz tone standing in for speech (RMS ≈ amplitude / √2).
        case speech(seconds: Double, amplitude: Float)
    }

    /// Every part gets the noise bed; speech parts add a tone on top.
    private func audio(_ parts: [Part], noise amplitude: Float) -> [Float] {
        var noise = Noise()
        var samples: [Float] = []
        for part in parts {
            switch part {
            case .noise(let seconds):
                samples += (0..<Int(seconds * Double(rate))).map { _ in noise.next(amplitude) }
            case .speech(let seconds, let tone):
                samples += (0..<Int(seconds * Double(rate))).map { i in
                    tone * sin(2 * .pi * 220 * Float(i) / Float(rate)) + noise.next(amplitude)
                }
            }
        }
        return samples
    }

    private func isClose(_ a: Double, _ b: Double, within tolerance: Double = 0.11) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func noisyFloorUsesNoiseFactor() {
        let samples = audio([.noise(seconds: 10), .speech(seconds: 3, amplitude: 0.01), .noise(seconds: 10)], noise: 0.003)
        let threshold = SpeechRegions.threshold(in: samples, sampleRate: rate)
        #expect(threshold > SpeechRegions.Tuning.absoluteFloor && threshold < SpeechRegions.Tuning.ceiling)
        let clips = SpeechRegions.clips(in: samples, sampleRate: rate)
        #expect(clips.count == 1, "clips: \(clips)")
        #expect(isClose(clips.first?.start ?? -1, 9.5) && isClose(clips.first?.end ?? -1, 13.5), "clips: \(clips)")
    }

    @Test func heavyNoiseBedIsCappedAtCeiling() {
        let samples = audio([.noise(seconds: 10), .speech(seconds: 3, amplitude: 0.05), .noise(seconds: 10)], noise: 0.02)
        #expect(SpeechRegions.threshold(in: samples, sampleRate: rate) == SpeechRegions.Tuning.ceiling)
        let clips = SpeechRegions.clips(in: samples, sampleRate: rate)
        #expect(clips.count == 1, "clips: \(clips)")
        #expect(isClose(clips.first?.start ?? -1, 9.5) && isClose(clips.first?.end ?? -1, 13.5), "clips: \(clips)")
    }

    @Test func shortGapMergesLongGapSplits() {
        let tone = Part.speech(seconds: 2, amplitude: 0.1)
        // Padding shrinks a 2.5 s gap to 1.5 s (< minSilence); a 5 s gap stays 4 s.
        let short = audio([.noise(seconds: 5), tone, .noise(seconds: 2.5), tone, .noise(seconds: 5)], noise: 0)
        #expect(SpeechRegions.clips(in: short, sampleRate: rate).count == 1)

        let long = audio([.noise(seconds: 5), tone, .noise(seconds: 5), tone, .noise(seconds: 5)], noise: 0)
        let clips = SpeechRegions.clips(in: long, sampleRate: rate)
        #expect(clips.count == 2, "clips: \(clips)")
        #expect(isClose(clips.first?.end ?? -1, 7.5) && isClose(clips.last?.start ?? -1, 11.5), "clips: \(clips)")
    }

    @Test func clipsAreClampedToFile() {
        let samples = audio([.speech(seconds: 3, amplitude: 0.1), .noise(seconds: 10), .speech(seconds: 3, amplitude: 0.1)], noise: 0)
        let duration = Double(samples.count) / Double(rate)
        let clips = SpeechRegions.clips(in: samples, sampleRate: rate)
        #expect(clips.count == 2, "clips: \(clips)")
        #expect(clips.first?.start == 0)
        #expect(clips.last?.end == duration)
    }

    @Test func allSilenceGivesNoClips() {
        #expect(SpeechRegions.clips(in: audio([.noise(seconds: 30)], noise: 0), sampleRate: rate).isEmpty)
        #expect(SpeechRegions.clips(in: [], sampleRate: rate).isEmpty)
    }

    /// WhisperKit skips clips of 1 s or less, so a short utterance is widened to `minClip`.
    @Test func shortUtteranceAtStartIsWidenedToMinimumClip() {
        let samples = audio([.speech(seconds: 0.4, amplitude: 0.1), .noise(seconds: 10)], noise: 0)
        let clips = SpeechRegions.clips(in: samples, sampleRate: rate)
        #expect(clips.count == 1, "clips: \(clips)")
        #expect(clips.first?.start == 0)
        #expect((clips.first?.duration ?? 0) >= SpeechRegions.Tuning.minClip - 1e-9, "clips: \(clips)")
        #expect(isClose(clips.first?.end ?? -1, SpeechRegions.Tuning.minClip, within: 1e-9))
    }
}
