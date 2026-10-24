import Foundation

public enum Stage: String, Codable, Sendable {
    /// Recorded and saved, not processed yet: nothing runs (or is paid for) until the user presses Process.
    case ready
    case transcribing, writingNotes, verifying, saving, done, failed
}

/// One recorded part of a lecture that is ready to process: its audio file in the lecture folder and its
/// pauses on the part's own timeline. Process places the pauses on the joined timeline.
public struct RecordedPart: Codable, Equatable, Sendable {
    /// The file name inside the lecture folder, e.g. `audio-2.m4a`.
    public var file: String
    public var pauses: [TranscriptMarker]

    public init(file: String, pauses: [TranscriptMarker]) {
        self.file = file
        self.pauses = pauses
    }
}

/// One paid API call, kept so a retry can still price it in the notes header.
public struct PaidCall: Codable, Equatable, Sendable {
    public var model: String
    public var usage: Usage
    /// Set when the call ran on the Claude subscription: the limits' use right after it.
    public var subscription: SubscriptionLimits?

    public init(model: String, usage: Usage, subscription: SubscriptionLimits? = nil) {
        self.model = model
        self.usage = usage
        self.subscription = subscription
    }

    /// The call's price in USD, or nil when the model has no known price. Subscription calls cost nothing.
    public var usd: Double? { subscription != nil ? 0 : apiUSD }

    /// What the call costs at API prices, also for a subscription call. nil when the model has no known price.
    public var apiUSD: Double? { Pricing.usd(model: model, usage: usage) }
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
    /// The style's short display name for the notes header, recorded at the notes stage so saving
    /// doesn't depend on the style file still being there.
    public var styleName: String?
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
    /// The recorded parts while the lecture is `.ready`, in order; nil otherwise and in older state files.
    public var parts: [RecordedPart]?

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
    /// nil when there is nothing to resume (ready, done, or failed without a stage).
    public var resumeStage: Stage? {
        switch stage {
        case .ready, .done: nil
        case .failed: failedStage
        default: stage
        }
    }
}

extension PipelineState {
    /// Why a run starting at `stage` can't go ahead because one of its input files was deleted, or nil.
    /// The audio is needed only to transcribe again: not when the stored transcript for this audio is
    /// reusable (`transcriptReusable`) and no re-transcription is forced. The slides are needed until the
    /// check has run, the notes file until the notes are written. Names the first missing file.
    public func deletedInputMessage(startingAt stage: Stage, transcriptReusable: Bool,
                                    exists: (URL) -> Bool) -> String? {
        var needed: [URL] = []
        if stage == .transcribing, forceRetranscribe || !transcriptReusable { needed += audio }
        if [.transcribing, .writingNotes, .verifying].contains(stage) { needed += slides }
        if [.transcribing, .writingNotes].contains(stage), let userNotes { needed.append(userNotes) }
        return needed.first { !exists($0) }.map { "Can't process again: \($0.lastPathComponent) was deleted" }
    }
}

extension PipelineState {
    /// This fresh state with `previous`'s paid draft and check carried over, when `previous` is an unfinished
    /// run that made them from the same audio, slides, notes file, style, 💡 setting and language, and no
    /// re-transcription is asked for. `Pipeline.run` then resumes from the draft instead of paying for the
    /// notes again (it also checks the draft file and the speech model). A finished lecture is never carried
    /// over: processing it again writes fresh notes (ruling R35). Otherwise the state is returned unchanged.
    public func carryingPaidDraft(from previous: PipelineState) -> PipelineState {
        guard previous.stage != .done, previous.draftNotesFile != nil, previous.notesCall != nil, !forceRetranscribe,
              Self.samePaths(previous.audio, audio), Self.samePaths(previous.slides, slides),
              Self.samePaths(previous.userNotes.map { [$0] } ?? [], userNotes.map { [$0] } ?? []),
              previous.styleID == styleID, previous.allowAdditions == allowAdditions, previous.language == language
        else { return self }
        var s = self
        s.transcriptionModel = previous.transcriptionModel
        s.draftNotesFile = previous.draftNotesFile
        s.styleName = previous.styleName
        s.notesCall = previous.notesCall
        s.verifyCall = previous.verifyCall
        s.findings = previous.findings
        s.verificationSkipped = previous.verificationSkipped
        return s
    }

    static func samePaths(_ a: [URL], _ b: [URL]) -> Bool {
        func paths(_ urls: [URL]) -> [String] { urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path } }
        return paths(a) == paths(b)
    }
}
