import Accelerate
import Foundation

/// A stretch of audio to transcribe, in seconds from the start of the file.
public struct SpeechClip: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// Energy-based voice activity detection that finds the parts of a recording worth sending to
/// Whisper. Whisper invents text during long silences, so those are skipped.
public enum SpeechRegions {
    /// Tuning. A laptop mic in a lecture room records the speaker quietly, so the speech threshold
    /// adapts to the recording: `min(ceiling, max(absoluteFloor, noiseFloor * noiseFactor))`, where
    /// the noise floor is the `noisePercentile` of frame RMS values (lectures have pauses, so the
    /// quietest frames are room noise). The ceiling keeps a loud noise bed (a fan) from pushing the
    /// threshold above quiet speech.
    public enum Tuning {
        /// Frame length for RMS measurement, in seconds.
        public static let frameLength = 0.1
        public static let noisePercentile = 0.1
        public static let noiseFactor: Float = 3
        public static let absoluteFloor: Float = 0.0005
        /// WhisperKit's own fixed `EnergyVAD` threshold.
        public static let ceiling: Float = 0.02
        /// Speech regions are padded by this many seconds on each side.
        public static let padding = 0.5
        /// Only silences at least this long are skipped; shorter gaps stay inside one clip.
        public static let minSilence = 2.0
        /// WhisperKit skips clips of 1 s or less (`windowClipTime`), so clips are at least this long.
        public static let minClip = 1.1
        /// When no speech is found in a recording longer than this, the caller should transcribe
        /// the whole file rather than return nothing.
        public static let fallbackMinDuration = 5.0
    }

    /// The RMS level above which a frame counts as speech.
    public static func threshold(in samples: [Float], sampleRate: Int) -> Float {
        threshold(energies: frameEnergies(samples, sampleRate: sampleRate))
    }

    private static func threshold(energies frameEnergies: [Float]) -> Float {
        let energies = frameEnergies.sorted()
        guard !energies.isEmpty else { return Tuning.absoluteFloor }
        let noiseFloor = energies[Int(Double(energies.count - 1) * Tuning.noisePercentile)]
        return min(Tuning.ceiling, max(Tuning.absoluteFloor, noiseFloor * Tuning.noiseFactor))
    }

    /// Speech clips, sorted and non-overlapping, each padded by `Tuning.padding`, at least
    /// `Tuning.minClip` long (when the file is), merged across gaps shorter than `Tuning.minSilence`,
    /// and clamped to the file. Empty when no frame is above the threshold.
    public static func clips(in samples: [Float], sampleRate: Int) -> [SpeechClip] {
        let rate = Double(sampleRate)
        let duration = Double(samples.count) / rate
        let frame = frameSamples(sampleRate)
        let energies = frameEnergies(samples, sampleRate: sampleRate)
        let threshold = threshold(energies: energies)

        var clips: [SpeechClip] = []
        var activeStart: Int?
        // A trailing silent sentinel closes a region that runs to the end of the file.
        for (index, energy) in (energies + [0]).enumerated() {
            if energy > threshold {
                if activeStart == nil { activeStart = index }
            } else if let start = activeStart {
                let region = SpeechClip(
                    start: Double(start * frame) / rate,
                    end: Double(min(index * frame, samples.count)) / rate)
                append(widened(region, duration: duration), to: &clips)
                activeStart = nil
            }
        }
        return clips
    }

    private static func widened(_ region: SpeechClip, duration: Double) -> SpeechClip {
        var clip = SpeechClip(
            start: max(0, region.start - Tuning.padding),
            end: min(duration, region.end + Tuning.padding))
        if clip.duration < Tuning.minClip {
            let middle = (clip.start + clip.end) / 2
            clip = SpeechClip(start: middle - Tuning.minClip / 2, end: middle + Tuning.minClip / 2)
            if clip.start < 0 { clip = SpeechClip(start: 0, end: clip.end - clip.start) }
            if clip.end > duration { clip = SpeechClip(start: clip.start - (clip.end - duration), end: duration) }
            clip.start = max(0, clip.start)
        }
        return clip
    }

    private static func append(_ clip: SpeechClip, to clips: inout [SpeechClip]) {
        if let last = clips.last, clip.start - last.end < Tuning.minSilence {
            clips[clips.count - 1].end = max(last.end, clip.end)
        } else {
            clips.append(clip)
        }
    }

    private static func frameSamples(_ sampleRate: Int) -> Int {
        max(1, Int(Tuning.frameLength * Double(sampleRate)))
    }

    private static func frameEnergies(_ samples: [Float], sampleRate: Int) -> [Float] {
        let frame = frameSamples(sampleRate)
        return samples.withUnsafeBufferPointer { buffer in
            stride(from: 0, to: buffer.count, by: frame).map { start in
                var rms: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + start, 1, &rms, vDSP_Length(min(frame, buffer.count - start)))
                return rms
            }
        }
    }
}
