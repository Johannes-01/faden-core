import AVFoundation
import Foundation

public protocol MessageSending: Sendable {
    func send(_ r: MessageRequest) async throws -> MessageResult
}

extension AnthropicClient: MessageSending {}

public enum PipelineError: Error, Equatable {
    case noAudio
    case noSpeech
    case missingDraft
}

/// Runs transcribe → write notes → verify → save for one lecture folder, persisting `.faden/state.json`
/// before each stage so a failed run can be retried from the stage that failed.
public actor Pipeline {
    public typealias DurationLoader = @Sendable (URL) async throws -> TimeInterval

    /// The lecture folder; it moves when saving renames a placeholder-titled folder.
    public private(set) var folder: LectureFolder
    /// Each stage as it starts, then `.done` or `.failed`.
    public nonisolated let progress: AsyncStream<Stage>

    private let continuation: AsyncStream<Stage>.Continuation
    private let transcriber: Transcriber
    private let client: MessageSending
    private let styles: StyleStore
    private let ledger: CostLedger
    private let now: @Sendable () -> Date
    private let duration: DurationLoader
    /// True while `run` or `retry` is working; a second call meanwhile returns `current` unchanged.
    private var isRunning = false
    /// The state of the run in progress, or of the last one.
    private var current: PipelineState?

    static let draftName = "draft-notes.md"

    public init(folder: LectureFolder, transcriber: Transcriber, client: MessageSending, styles: StyleStore,
                ledger: CostLedger, now: @escaping @Sendable () -> Date,
                duration: @escaping DurationLoader = Pipeline.audioDuration) {
        self.folder = folder
        self.transcriber = transcriber
        self.client = client
        self.styles = styles
        self.ledger = ledger
        self.now = now
        self.duration = duration
        (progress, continuation) = AsyncStream.makeStream(of: Stage.self)
    }

    deinit { continuation.finish() }

    /// The audio file's length in seconds, read with AVFoundation.
    public static let audioDuration: DurationLoader = { url in
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// Runs from `state.stage` (a finished or failed state starts over at transcribing) until done or failed.
    /// A state that carries a reusable paid draft (see `PipelineState.carryingPaidDraft`) resumes from it,
    /// so the notes aren't paid for twice. While another run is in progress it returns that run's current
    /// state and does nothing.
    public func run(_ state: PipelineState) async -> PipelineState {
        guard !isRunning else { return current ?? state }
        isRunning = true
        defer { isRunning = false }
        var s = state
        if s.stage == .done || s.stage == .failed { s.stage = .transcribing }
        if s.stage == .transcribing, let resume = paidDraftStage(s) { s.stage = resume }
        return await execute(s)
    }

    /// Where a state carrying a paid draft resumes: at saving when the check was paid for too, otherwise
    /// at verifying. nil when the draft can't be reused: re-transcription is forced, the draft or the
    /// transcript is missing, or the transcript came from another speech model than this run's.
    private func paidDraftStage(_ s: PipelineState) -> Stage? {
        let fm = FileManager.default
        guard !s.forceRetranscribe, s.notesCall != nil, let name = s.draftNotesFile,
              fm.fileExists(atPath: draftURL(name).path), fm.fileExists(atPath: folder.transcriptMetaURL.path),
              s.transcriptionModel == transcriber.modelName
        else { return nil }
        return s.verifyCall != nil ? .saving : .verifying
    }

    /// Loads `state.json` and resumes at its `failedStage`, or at the stage a crash interrupted.
    /// A finished state, or a failure with no stage to resume, is returned unchanged so nothing is paid twice.
    /// While another run is in progress it returns that run's current state and does nothing.
    public func retry() async -> PipelineState {
        if isRunning, let current { return current }
        isRunning = true
        defer { isRunning = false }
        let state: PipelineState
        do {
            state = try JSONDecoder().decode(PipelineState.self, from: Data(contentsOf: folder.stateURL))
        } catch {
            var failed = PipelineState(stage: .failed, audio: [], styleID: "", allowAdditions: true)
            failed.error = "Could not read the saved progress: \(error.localizedDescription)"
            continuation.yield(.failed)
            return failed
        }
        if state.stage == .done { return state }
        var resumed = state
        if state.stage == .failed {
            guard let stage = state.failedStage else { return state }
            resumed.stage = stage
        }
        return await execute(resumed)
    }

    private func execute(_ state: PipelineState) async -> PipelineState {
        var s = state
        s.error = nil
        s.failedStage = nil
        while s.stage != .done && s.stage != .failed {
            let stage = s.stage
            do {
                try checkpoint(s)
                continuation.yield(stage)
                s = try await perform(stage, s)
            } catch {
                s.stage = .failed
                s.failedStage = stage
                s.error = Self.message(for: error)
            }
        }
        // Best effort: the outcome is already on disk (notes) or in `s.error`.
        try? checkpoint(s)
        continuation.yield(s.stage)
        return s
    }

    // MARK: - Stages

    private func perform(_ stage: Stage, _ state: PipelineState) async throws -> PipelineState {
        switch stage {
        case .transcribing: try await transcribe(state)
        case .writingNotes: try await writeNotes(state)
        case .verifying: try await verify(state)
        case .saving: try save(state)
        case .done, .failed: state
        }
    }

    private func transcribe(_ state: PipelineState) async throws -> PipelineState {
        var s = state
        guard !s.audio.isEmpty else { throw PipelineError.noAudio }
        s.transcriptionModel = transcriber.modelName
        s.draftNotesFile = nil
        s.notesCall = nil
        s.verifyCall = nil
        s.findings = nil
        s.verificationSkipped = nil

        var transcript: Transcript
        if let reused = reusableTranscript(for: s) {
            transcript = reused
        } else {
            var parts: [(file: String, transcript: Transcript, duration: TimeInterval)] = []
            for url in s.audio {
                let part = try await transcriber.transcribe(audio: url, language: s.language)
                parts.append((url.lastPathComponent, part, try await duration(url)))
            }
            transcript = Transcript.concatenate(parts)
            transcript.model = transcriber.modelName
        }
        // A reused transcript may already carry these pauses.
        for marker in s.markers where !transcript.markers.contains(marker) {
            transcript.markers.append(marker)
        }

        try createFadenDirectory()
        try Data(transcript.markdown().utf8).write(to: folder.transcriptURL, options: .atomic)
        try JSONEncoder().encode(transcript).write(to: folder.transcriptMetaURL, options: .atomic)
        guard !transcript.isEffectivelyEmpty else { throw PipelineError.noSpeech }
        s.stage = .writingNotes
        return s
    }

    /// The folder's stored transcript, when every audio file lives in this folder, it was made with the
    /// current model, it covers the same files, and no re-transcription was asked for. All or nothing.
    private func reusableTranscript(for s: PipelineState) -> Transcript? {
        guard !s.forceRetranscribe else { return nil }
        let dir = folder.url.resolvingSymlinksInPath().path
        guard s.audio.allSatisfy({ $0.resolvingSymlinksInPath().deletingLastPathComponent().path == dir }),
              let data = try? Data(contentsOf: folder.transcriptMetaURL),
              let stored = try? JSONDecoder().decode(Transcript.self, from: data),
              stored.model == transcriber.modelName
        else { return nil }
        // `concatenate` marks each part's file only when there are several.
        let storedFiles = stored.markers.compactMap { marker -> String? in
            if case .part(_, let file, _) = marker { file } else { nil }
        }
        let files = s.audio.count > 1 ? s.audio.map(\.lastPathComponent) : []
        return storedFiles == files ? stored : nil
    }

    private func writeNotes(_ state: PipelineState) async throws -> PipelineState {
        var s = state
        let style = try styles.resolve(id: s.styleID, hasSlides: !s.slides.isEmpty)
        let request = try NotesPrompt.request(NotesInputs(
            transcript: try loadTranscript(), slides: s.slides, userNotes: s.userNotes, style: style,
            allowAdditions: s.allowAdditions, languageOverride: s.language))
        let result = try await client.send(request)

        try createFadenDirectory()
        try Data(result.text.utf8).write(to: draftURL(Self.draftName), options: .atomic)
        s.draftNotesFile = Self.draftName
        s.styleName = Self.shortName(style)
        let call = PaidCall(model: result.model, usage: result.usage)
        s.notesCall = call
        record(call)
        s.stage = .verifying
        // Saved straight away: a crash from here on resumes at verifying and never pays for the notes again.
        try checkpoint(s)
        return s
    }

    /// Any failure here is recorded as `skipped (reason)`; it never fails the pipeline.
    private func verify(_ state: PipelineState) async throws -> PipelineState {
        var s = state
        let notes = try loadDraft(s)
        s.verifyCall = nil
        s.findings = nil
        s.verificationSkipped = nil
        let result: MessageResult
        do {
            let request = try Verifier.request(notes: notes, transcript: try loadTranscript(), slides: s.slides)
            result = try await client.send(request)
        } catch {
            s.verificationSkipped = "skipped (\(Self.skipReason(error)))"
            s.stage = .saving
            return s
        }
        let call = PaidCall(model: result.model, usage: result.usage)
        s.verifyCall = call
        record(call)
        do {
            s.findings = try Verifier.parse(result.text)
        } catch {
            s.verificationSkipped = "skipped (\(Self.skipReason(error)))"
        }
        s.stage = .saving
        // Saved straight away: a crash from here on resumes at saving and never pays for the check again.
        try checkpoint(s)
        return s
    }

    private func save(_ state: PipelineState) throws -> PipelineState {
        var s = state
        let draft = try loadDraft(s)
        let findings = s.findings ?? []
        let merged = Verifier.merge(findings, into: draft)
        // States saved before `styleName` existed resolve the style file instead.
        let styleName = try s.styleName ?? Self.shortName(styles.resolve(id: s.styleID, hasSlides: !s.slides.isEmpty))

        let header = NotesHeader(
            date: now(), style: styleName, slides: s.slides.map(\.lastPathComponent),
            audio: s.audio.map(\.lastPathComponent), userNotes: s.userNotes?.lastPathComponent,
            notesCall: s.notesCall ?? PaidCall(model: NotesPrompt.model, usage: Usage()), verifyCall: s.verifyCall,
            verification: s.verificationSkipped ?? "ok, \(findings.count - merged.unmatched) flagged")

        let target = folder.newNotesURL(now: now())
        try Data(header.insert(into: merged.notes).utf8).write(to: target, options: .withoutOverwriting)

        if s.titleIsPlaceholder, s.slides.isEmpty, let title = Self.title(of: draft) {
            let old = folder
            // The notes are saved; a folder that can't be renamed keeps its placeholder name.
            if let renamed = try? old.rename(toTitle: title, date: Self.folderDate(old) ?? now()) {
                folder = renamed
                s = Self.relocate(s, from: old.url, to: renamed.url)
                s.titleIsPlaceholder = false
            }
        }
        s.stage = .done
        return s
    }

    // MARK: - Helpers

    /// Remembers `s` as the current state and writes it to `state.json`.
    private func checkpoint(_ s: PipelineState) throws {
        current = s
        try createFadenDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(s).write(to: folder.stateURL, options: .atomic)
    }

    private func createFadenDirectory() throws {
        try FileManager.default.createDirectory(
            at: folder.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func draftURL(_ name: String) -> URL {
        folder.stateURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func loadDraft(_ s: PipelineState) throws -> String {
        guard let name = s.draftNotesFile,
              let data = try? Data(contentsOf: draftURL(name)),
              let text = String(data: data, encoding: .utf8)
        else { throw PipelineError.missingDraft }
        return text
    }

    private func loadTranscript() throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: folder.transcriptMetaURL))
    }

    /// Cost tracking is best effort: a ledger that can't be written must not fail (and re-bill) a paid stage.
    private func record(_ call: PaidCall) {
        try? ledger.append(CostRecord(
            date: now(), lecture: folder.url.lastPathComponent, model: call.model, usage: call.usage,
            usd: Pricing.usd(model: call.model, usage: call.usage)))
    }

    /// `C` for the bundled `C · Red line first, then detail`; a custom style's full name otherwise.
    static func shortName(_ style: NoteStyle) -> String {
        style.name.components(separatedBy: " · ").first ?? style.name
    }

    /// The text of a leading `# Title` line.
    static func title(of notes: String) -> String? {
        guard notes.hasPrefix("# ") else { return nil }
        let line = notes.prefix { $0 != "\n" && $0 != "\r" }.dropFirst(2)
        let title = line.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// The `yyyy-MM-dd` date a lecture folder's name starts with.
    static func folderDate(_ folder: LectureFolder) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(folder.url.lastPathComponent.prefix(10)))
    }

    /// Points URLs inside the old folder at the renamed folder.
    static func relocate(_ state: PipelineState, from old: URL, to new: URL) -> PipelineState {
        let prefix = old.standardizedFileURL.path + "/"
        func move(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return url }
            return new.appendingPathComponent(String(path.dropFirst(prefix.count)))
        }
        var s = state
        s.audio = s.audio.map(move)
        s.slides = s.slides.map(move)
        s.userNotes = s.userNotes.map(move)
        return s
    }

    static func message(for error: Error) -> String {
        switch error {
        case PipelineError.noAudio: return "No audio to process"
        case PipelineError.noSpeech: return "No speech found"
        case PipelineError.missingDraft: return "The draft notes are missing; process the lecture again"
        case AnthropicError.missingKey: return "Add your Anthropic API key in Settings"
        case AnthropicError.refused(let category):
            return "The model declined this lecture (category: \(category ?? "unknown"))"
        case AnthropicError.http(let status, _, let message):
            return "The Anthropic API returned HTTP \(status)" + (message.map { ": \($0)" } ?? "")
        case AnthropicError.truncated: return "The notes were cut off at the output limit"
        case AnthropicError.streamIncomplete: return "The connection dropped before the notes were complete"
        case AnthropicError.network(let message): return "Network error: \(message)"
        case StyleStoreError.notFound(let id): return "Note style \"\(id)\" not found"
        case StyleStoreError.malformed(let id): return "Note style \"\(id)\" could not be read"
        case SlideInputError.unreadablePDF(let name): return "Could not read the slides \"\(name)\""
        default: return error.localizedDescription
        }
    }

    static func skipReason(_ error: Error) -> String {
        switch error {
        case AnthropicError.http(let status, _, _): "HTTP \(status)"
        case AnthropicError.refused: "refused"
        case is DecodingError: "unreadable response"
        default: message(for: error)
        }
    }
}
