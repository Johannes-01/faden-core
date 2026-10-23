import FadenCore
import Foundation
import WhisperKit

public enum TranscriptionModel: String, CaseIterable, Codable, Sendable {
    case fast, accurate

    /// The WhisperKit model variant, as listed in the WhisperKit 1.1.1 README.
    public var whisperKitVariant: String {
        switch self {
        case .fast: "small"
        case .accurate: "large-v3-v20240930_turbo"
        }
    }
}

/// Transcribes on-device with WhisperKit. The model downloads into WhisperKit's default
/// cache on first use (model files only; audio never leaves the Mac), then loads once and
/// is reused for later calls.
public actor WhisperKitTranscriber: Transcriber {
    public nonisolated let modelName: String
    /// Started on the first `transcribe`; concurrent first calls await the same load.
    private var loading: Task<PipeBox, any Error>?

    public init(model: TranscriptionModel) {
        modelName = model.whisperKitVariant
    }

    /// - Parameter language: An ISO code such as `"de"` to force, or `nil` to auto-detect.
    public func transcribe(audio: URL, language: String?) async throws -> Transcript {
        let pipe = try await loadedPipe()
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
        let speech = Self.speechClips(in: samples)
        guard !speech.isEmpty else {
            return Transcript(segments: [], markers: [], language: language, model: modelName)
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            clipTimestamps: speech.flatMap { [$0.start, $0.end] },
            chunkingStrategy: .vad)
        // Only the speech clips are decoded. WhisperKit reports segment times from the start of
        // the array (seek position, plus each VAD chunk's offset), so they are file positions.
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        let segments = results
            .flatMap(\.segments)
            .compactMap { segment -> TranscriptSegment? in
                let text = Self.clean(segment.text)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(start: TimeInterval(segment.start), end: TimeInterval(segment.end), text: text)
            }
            .sorted { $0.start < $1.start }
        return Transcript(
            segments: segments, markers: [],
            language: language ?? Self.dominantLanguage(of: results),
            model: modelName)
    }

    /// Voice activity tuning. A laptop mic in a lecture room records the speaker quietly, so the
    /// speech threshold adapts to the recording instead of WhisperKit's fixed 0.02 RMS:
    /// `max(absoluteFloor, noiseFloor * noiseFactor)`, where the noise floor is the
    /// `noisePercentile` of 100 ms frame RMS values (lectures have pauses, so the low frames are room noise).
    enum VAD {
        static let frameLength: Float = 0.1
        static let noisePercentile = 0.1
        static let noiseFactor: Float = 3
        static let absoluteFloor: Float = 0.0005
        /// Speech regions are padded by this many seconds on each side.
        static let padding: Float = 0.5
        /// Only silences at least this long are skipped; shorter gaps stay inside one clip.
        static let minSilence: Float = 2
    }

    static func speechThreshold(in samples: [Float]) -> Float {
        let frame = Int(VAD.frameLength * Float(WhisperKit.sampleRate))
        let energies = stride(from: 0, to: samples.count, by: frame)
            .map { AudioProcessor.calculateAverageEnergy(of: Array(samples[$0..<min($0 + frame, samples.count)])) }
            .sorted()
        guard !energies.isEmpty else { return VAD.absoluteFloor }
        let noiseFloor = energies[Int(Double(energies.count - 1) * VAD.noisePercentile)]
        return max(VAD.absoluteFloor, noiseFloor * VAD.noiseFactor)
    }

    /// Speech regions in seconds, found with WhisperKit's energy VAD at the adaptive threshold,
    /// padded by `VAD.padding` and merged across gaps shorter than `VAD.minSilence`.
    static func speechClips(in samples: [Float]) -> [(start: Float, end: Float)] {
        let rate = Float(WhisperKit.sampleRate)
        let duration = Float(samples.count) / rate
        let padding = VAD.padding, minSilence = VAD.minSilence
        let vad = EnergyVAD(frameLength: VAD.frameLength, energyThreshold: speechThreshold(in: samples))
        var clips: [(start: Float, end: Float)] = []
        for chunk in vad.calculateActiveChunks(in: samples) {
            let start = max(0, Float(chunk.startIndex) / rate - padding)
            let end = min(duration, Float(chunk.endIndex) / rate + padding)
            if let last = clips.last, start - last.end < minSilence {
                clips[clips.count - 1].end = end
            } else {
                clips.append((start, end))
            }
        }
        return clips
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let loading { return try await loading.value.pipe }
        let model = modelName
        let task = Task {
            PipeBox(pipe: try await WhisperKit(WhisperKitConfig(model: model, verbose: false, load: true, download: true)))
        }
        loading = task
        do {
            return try await task.value.pipe
        } catch {
            loading = nil  // let a later call retry, e.g. after a failed download
            throw error
        }
    }

    /// Strips Whisper special tokens such as `<|de|>` or `<|0.00|>`, drops non-speech
    /// annotations such as `[BLANK_AUDIO]`, and trims whitespace.
    static func clean(_ text: String) -> String {
        let stripped = text.replacing(/<\|[^|>]*\|>/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.wholeMatch(of: /\[[A-Z_ ]+\]/) == nil ? stripped : ""
    }

    /// VAD chunks detect their language separately; pick the one that carries the most text.
    private static func dominantLanguage(of results: [TranscriptionResult]) -> String? {
        var weight: [String: Int] = [:]
        for result in results {
            weight[result.language, default: 0] += result.segments.reduce(0) { $0 + clean($1.text).count }
        }
        return weight.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? results.first?.language
    }
}

/// Carries the non-Sendable pipe out of the loading `Task`. The pipe is only reached through
/// `WhisperKitTranscriber`; the app transcribes one recording at a time.
private final class PipeBox: @unchecked Sendable {
    let pipe: WhisperKit
    init(pipe: WhisperKit) { self.pipe = pipe }
}
