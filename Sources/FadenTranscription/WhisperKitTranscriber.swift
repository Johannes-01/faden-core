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
    /// The latest transcription. Each call waits for the previous one, so two transcriptions
    /// never run on the shared WhisperKit instance at once.
    private var current: Task<Transcript, any Error>?

    public init(model: TranscriptionModel) {
        modelName = model.whisperKitVariant
    }

    /// - Parameter language: An ISO code such as `"de"` to force, or `nil` to auto-detect.
    public func transcribe(audio: URL, language: String?) async throws -> Transcript {
        let previous = current
        let task = Task {
            _ = await previous?.result
            return try await self.run(audio: audio, language: language)
        }
        current = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func run(audio: URL, language: String?) async throws -> Transcript {
        let pipe = try await loadedPipe()
        try Task.checkCancellation()
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
        let speech = SpeechRegions.clips(in: samples, sampleRate: WhisperKit.sampleRate)
        let duration = Double(samples.count) / Double(WhisperKit.sampleRate)
        if speech.isEmpty && duration <= SpeechRegions.Tuning.fallbackMinDuration {
            return Transcript(segments: [], markers: [], language: language, model: modelName)
        }
        // No speech found in a longer file means the VAD is wrong about this recording (for
        // example a noise bed above quiet speech), so transcribe all of it instead of nothing.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            clipTimestamps: speech.flatMap { [Float($0.start), Float($0.end)] },
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

/// Carries the non-Sendable pipe out of the loading `Task`. The pipe is only used from
/// `WhisperKitTranscriber.run`, and runs are serialised.
private final class PipeBox: @unchecked Sendable {
    let pipe: WhisperKit
    init(pipe: WhisperKit) { self.pipe = pipe }
}
