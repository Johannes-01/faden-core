import Foundation
import os

public enum ReadyLectureError: Error, Equatable, LocalizedError {
    /// A recorded part's audio file is gone; carries its name.
    case deleted(String)
    /// Recorded parts in the folder that the lecture doesn't list yet; carries their names. Include them first.
    case unlisted([String])

    public var errorDescription: String? {
        switch self {
        case .deleted(let name): "Can't process: \(name) was deleted"
        case .unlisted(let names):
            "Can't process: \(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") not in this lecture yet. "
                + "Include \(names.count == 1 ? "it" : "them") on the review card first."
        }
    }
}

/// A recorded lecture that waits for Process: Stop saved its audio parts into the lecture folder, and nothing
/// is transcribed or sent anywhere until the user processes it. Saved as `.faden/state.json` at stage `.ready`,
/// so it survives a quit; Continue recording adds parts, and the slides and notes stay editable.
public struct ReadyLecture: Equatable, Sendable {
    /// Moves when the first slide renames a placeholder-titled folder.
    public private(set) var folder: LectureFolder
    public private(set) var state: PipelineState

    /// The recorded parts, in order.
    public var parts: [RecordedPart] {
        state.parts ?? state.audio.map { RecordedPart(file: $0.lastPathComponent, pauses: []) }
    }

    public var partCount: Int { parts.count }

    /// The audio files of the parts, in order.
    public var audio: [URL] { parts.map { folder.url.appendingPathComponent($0.file) } }

    /// The folder's lecture when its saved state is ready to process; nil otherwise (none, unreadable, or
    /// already processed or processing).
    public static func load(_ folder: LectureFolder) -> ReadyLecture? {
        guard let state = PipelineState.saved(in: folder), state.stage == .ready else { return nil }
        return ReadyLecture(folder: folder, state: state)
    }

    /// Adds the part Stop just saved at `audio` (inside `folder`) with its pauses, records the attachments and
    /// saves the lecture as ready to process. A folder without a ready state starts one; parts already on disk
    /// with a lower part number (e.g. a recovered continuation whose earlier state was lost) come first,
    /// without pauses. Settings are recorded too, but Process uses the ones current then.
    /// When the folder name is a placeholder and there are slides, it is renamed to the first slide's title.
    public static func addingPart(
        _ audio: URL, pauses: [TranscriptMarker], to folder: LectureFolder, slides: [URL], userNotes: URL?,
        styleID: String, allowAdditions: Bool, language: String?, titleIsPlaceholder: Bool, now: Date
    ) throws -> ReadyLecture {
        var lecture = load(folder) ?? ReadyLecture(folder: folder, state: {
            var state = PipelineState(
                stage: .ready, audio: [], styleID: styleID, allowAdditions: allowAdditions, language: language,
                titleIsPlaceholder: titleIsPlaceholder)
            let number = LectureFolder.partNumber(of: audio.lastPathComponent) ?? 1
            state.parts = folder.audioPartURLs()
                .filter { (LectureFolder.partNumber(of: $0.lastPathComponent) ?? .max) < number }
                .map { RecordedPart(file: $0.lastPathComponent, pauses: []) }
            return state
        }())
        var parts = lecture.parts
        let part = RecordedPart(file: audio.lastPathComponent, pauses: pauses)
        if let i = parts.firstIndex(where: { $0.file == part.file }) { parts[i] = part } else { parts.append(part) }
        lecture.state.parts = parts
        lecture.state.slides = slides
        lecture.state.userNotes = userNotes
        lecture.renameForFirstSlide(now: now)
        try lecture.save()
        return lecture
    }

    /// Changes the slides and notes during review and saves them. The first slide renames a placeholder-titled
    /// folder to the slide's title (`titleIsPlaceholder` becomes false); a folder that can't be renamed keeps its name.
    public mutating func setAttachments(slides: [URL], userNotes: URL?, now: Date) throws {
        state.slides = slides
        state.userNotes = userNotes
        renameForFirstSlide(now: now)
        try save()
    }

    /// Recorded part files in the folder (`audio.m4a`, `audio-N.m4a`) that the lecture doesn't list, in part
    /// order; e.g. a part Stop saved whose state couldn't be written. Process refuses to run while there are any,
    /// so no recording is silently left out.
    public func unlistedParts() -> [URL] {
        let listed = Set(parts.map(\.file))
        return folder.audioPartURLs().filter { !listed.contains($0.lastPathComponent) }
    }

    /// Adds `files` (part files in this folder) to the lecture without pauses, and saves it. The parts are kept
    /// in part-number order, so Process offsets later pauses by the real durations of all earlier parts.
    public mutating func include(_ files: [URL]) throws {
        var all = parts
        for file in files where !all.contains(where: { $0.file == file.lastPathComponent }) {
            all.append(RecordedPart(file: file.lastPathComponent, pauses: []))
        }
        let ordered = all.enumerated().sorted {
            let a = LectureFolder.partNumber(of: $0.element.file) ?? .max
            let b = LectureFolder.partNumber(of: $1.element.file) ?? .max
            return (a, $0.offset) < (b, $1.offset)
        }
        state.parts = ordered.map(\.element)
        try save()
    }

    /// The state Process runs: every part in order, the attachments, the given settings, and each part's pauses
    /// on the joined timeline, offset by the real durations (`duration`) of the parts before it.
    /// Throws `ReadyLectureError.deleted` when a part's audio file is gone, and `.unlisted` while the folder holds
    /// recorded parts the lecture doesn't list.
    public func processingState(styleID: String, allowAdditions: Bool, language: String?,
                                duration: Pipeline.DurationLoader) async throws -> PipelineState {
        let unlisted = unlistedParts()
        guard unlisted.isEmpty else { throw ReadyLectureError.unlisted(unlisted.map(\.lastPathComponent)) }
        let urls = audio
        if let gone = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw ReadyLectureError.deleted(gone.lastPathComponent)
        }
        var durations: [TimeInterval] = []
        for url in urls.dropLast() { durations.append(try await duration(url)) }
        return PipelineState(
            stage: .transcribing, audio: urls, slides: state.slides, userNotes: state.userNotes, styleID: styleID,
            allowAdditions: allowAdditions, language: language, titleIsPlaceholder: state.titleIsPlaceholder,
            markers: Self.combinedMarkers(parts.map(\.pauses), durations: durations))
    }

    /// The total length of all parts, or nil when one can't be read.
    public func totalDuration(duration: Pipeline.DurationLoader) async -> TimeInterval? {
        var durations: [TimeInterval] = []
        for url in audio {
            guard let d = try? await duration(url) else { return nil }
            durations.append(d)
        }
        return Self.totalDuration(durations: durations)
    }

    public static func totalDuration(durations: [TimeInterval]) -> TimeInterval {
        durations.reduce(0, +)
    }

    /// Each part's markers shifted by the summed `durations` of the parts before it (`durations[i]` is part i's).
    public static func combinedMarkers(_ partMarkers: [[TranscriptMarker]], durations: [TimeInterval]) -> [TranscriptMarker] {
        var offset: TimeInterval = 0
        var combined: [TranscriptMarker] = []
        for (i, markers) in partMarkers.enumerated() {
            combined += markers.map { $0.shifted(by: offset) }
            if i < durations.count { offset += durations[i] }
        }
        return combined
    }

    // MARK: - Private

    private mutating func renameForFirstSlide(now: Date) {
        guard state.titleIsPlaceholder, let first = state.slides.first else { return }
        let title = LectureFolder.title(fromSlide: first)
        guard !LectureFolder.sanitise(title).isEmpty else { return }
        let old = folder
        do {
            let renamed = try old.rename(toTitle: title, date: Pipeline.folderDate(old) ?? now)
            folder = renamed
            state = Pipeline.relocate(state, from: old.url, to: renamed.url)
            state.titleIsPlaceholder = false
        } catch {
            Self.log.error("Renaming \(old.url.lastPathComponent) to the slide title failed: \(error)")
        }
    }

    /// Writes `state.json` with `audio` matching the parts. Never creates the lecture folder itself.
    private mutating func save() throws {
        state.stage = .ready
        state.audio = audio
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.url.path) else {
            throw PipelineError.folderDeleted(folder.url.lastPathComponent)
        }
        try fm.createDirectory(at: folder.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: folder.stateURL, options: .atomic)
    }

    private static let log = Logger(subsystem: "de.haick.faden", category: "ReadyLecture")
}
