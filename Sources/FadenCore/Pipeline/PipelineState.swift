import Foundation

public enum Stage: String, Codable, Sendable {
    case transcribing, writingNotes, verifying, saving, done, failed
}

/// One paid API call, kept so a retry can still price it in the notes header.
public struct PaidCall: Codable, Equatable, Sendable {
    public var model: String
    public var usage: Usage

    public init(model: String, usage: Usage) {
        self.model = model
        self.usage = usage
    }
}

/// The pipeline's progress for one lecture, persisted as `.faden/state.json` before each stage.
public struct PipelineState: Codable, Equatable, Sendable {
    public var stage: Stage
    public var failedStage: Stage?
    public var error: String?
    /// In playback order.
    public var audio: [URL]
    public var slides: [URL]
    public var userNotes: URL?
    public var styleID: String
    public var allowAdditions: Bool
    public var language: String?
    /// Recorded by the pipeline from the transcriber it ran with.
    public var transcriptionModel: String
    public var forceRetranscribe: Bool
    /// Relative to `.faden/`.
    public var draftNotesFile: String?
    /// The folder name came from a placeholder title; saving renames it to the notes' `# Title` (without slides).
    public var titleIsPlaceholder: Bool
    /// Recording pauses on the concatenated timeline, applied after concatenation.
    public var markers: [TranscriptMarker]

    /// Results of the paid stages, kept so a retry never pays for them again.
    public var notesCall: PaidCall?
    public var verifyCall: PaidCall?
    public var findings: [Finding]?
    /// Set when verification was skipped, e.g. `skipped (HTTP 500)`.
    public var verificationSkipped: String?

    public init(
        stage: Stage = .transcribing,
        audio: [URL],
        slides: [URL] = [],
        userNotes: URL? = nil,
        styleID: String,
        allowAdditions: Bool,
        language: String? = nil,
        transcriptionModel: String = "",
        forceRetranscribe: Bool = false,
        titleIsPlaceholder: Bool = false,
        markers: [TranscriptMarker] = []
    ) {
        self.stage = stage
        self.audio = audio
        self.slides = slides
        self.userNotes = userNotes
        self.styleID = styleID
        self.allowAdditions = allowAdditions
        self.language = language
        self.transcriptionModel = transcriptionModel
        self.forceRetranscribe = forceRetranscribe
        self.titleIsPlaceholder = titleIsPlaceholder
        self.markers = markers
    }
}

extension PipelineState {
    /// The folder's saved `.faden/state.json`, or nil if there is none or it can't be read.
    public static func saved(in folder: LectureFolder) -> PipelineState? {
        guard let data = try? Data(contentsOf: folder.stateURL) else { return nil }
        return try? JSONDecoder().decode(PipelineState.self, from: data)
    }

    /// The stage `Pipeline.retry` resumes at: the failed stage, or the stage a crash interrupted.
    /// nil when there is nothing to resume (done, or failed without a stage).
    public var resumeStage: Stage? {
        switch stage {
        case .done: nil
        case .failed: failedStage
        default: stage
        }
    }
}
