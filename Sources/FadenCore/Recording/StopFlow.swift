import Foundation
import os

public enum StopFlowError: Error, Equatable, LocalizedError {
    /// The session has no segment files; there is nothing to save.
    case nothingRecorded
    /// Segment files exist but none holds readable audio (e.g. a CAF header never finalised after a
    /// hard crash). They are kept in `dir`.
    case unreadableAudio(dir: URL)
    /// The finaliser returned without writing its output file.
    case noFinalAudio
    /// The move returned but `audio.m4a` isn't at its destination.
    case audioNotDelivered

    public var errorDescription: String? {
        switch self {
        case .nothingRecorded: "Nothing was recorded"
        case .unreadableAudio(let dir): "The recorded audio could not be read. The files are kept in \(dir.path)"
        case .noFinalAudio: "Joining the recorded audio produced no file"
        case .audioNotDelivered: "The audio file did not arrive in the lecture folder"
        }
    }
}

/// The file side of Stop and of recovering an interrupted recording. Everything here keeps the
/// "never lose a recording" rule: segments are deleted only once `audio.m4a` is in the lecture folder.
public enum StopFlow {
    /// Joins `segments` into the `.m4a` at `output`; see `AudioFinalizer.finalize`.
    public typealias Finalize = @Sendable (_ segments: [URL], _ output: URL) async throws -> Void

    public struct Outcome: Sendable, Equatable {
        public let folder: LectureFolder
        /// The folder name is the `"Lecture HH-mm"` placeholder, not a slide title.
        public let titleIsPlaceholder: Bool
    }

    public static let defaultFinalize: Finalize = { segments, output in
        try await AudioFinalizer.finalize(segments: segments, to: output)
    }

    /// `"Lecture HH-mm"` from the recording's start time.
    public static func placeholderTitle(startedAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH-mm"
        return "Lecture \(f.string(from: startedAt))"
    }

    /// The first slide's title, otherwise the placeholder.
    public static func title(slides: [URL], startedAt: Date) -> (title: String, isPlaceholder: Bool) {
        if let first = slides.first {
            let title = LectureFolder.title(fromSlide: first)
            if !LectureFolder.sanitise(title).isEmpty { return (title, false) }
        }
        return (placeholderTitle(startedAt: startedAt), true)
    }

    /// Finalises the session's segments to a temporary `.m4a` inside the segment directory, creates
    /// the lecture folder in the session's course folder, moves the audio to `audio.m4a`, marks the
    /// session stopped and only then deletes the segment directory.
    ///
    /// `session.json` reads `.stopped` only once `audio.m4a` is in place; until then it keeps the
    /// caller's phase (`.finishing` after `AudioRecorder.stop()`), so `SegmentStore.unfinished` still
    /// lists the session if the process dies mid-save.
    ///
    /// On any failure nothing is deleted or marked stopped: the segments, `session.json` and the
    /// temporary `.m4a` (if the export got that far) stay where they are, and the error is rethrown.
    /// A lecture folder created before a failed move is left in place (empty).
    public static func finish(
        session: RecordingSession, slides: [URL], store: SegmentStore,
        finalize: Finalize = StopFlow.defaultFinalize
    ) async throws -> Outcome {
        let fm = FileManager.default
        let segments = store.segments()
        guard !segments.isEmpty else { throw StopFlowError.nothingRecorded }

        // A unique name: an earlier failed attempt's file is kept, and the finaliser never overwrites.
        let temp = store.dir.appendingPathComponent("finalised-\(UUID().uuidString).m4a")
        do {
            try await finalize(segments, temp)
        } catch AudioFinalizer.FinalizeError.noSegments where recordedDuration(of: segments) == 0 {
            throw StopFlowError.unreadableAudio(dir: store.dir)
        }
        guard fm.fileExists(atPath: temp.path) else { throw StopFlowError.noFinalAudio }

        let (title, isPlaceholder) = title(slides: slides, startedAt: session.startedAt)
        let folder = try LectureFolder.create(in: session.courseFolder, date: session.startedAt, title: title)
        try fm.moveItem(at: temp, to: folder.audioURL)
        guard fm.fileExists(atPath: folder.audioURL.path) else { throw StopFlowError.audioNotDelivered }

        // The audio is safe. Mark the session stopped first, so a failed delete can't bring it back
        // as "unfinished" on the next launch.
        var stopped = session
        stopped.stop()
        do {
            try store.save(stopped)
            try store.discard()
        } catch {
            log.error("Cleaning up the segments of \(session.id) failed: \(error)")
        }
        return Outcome(folder: folder, titleIsPlaceholder: isPlaceholder)
    }

    /// A session recovered in `.recording` (the app died while recording) or `.finishing` (it stopped
    /// but the save never completed) has no pause for the time since its last audio. Adds one at
    /// `recorded` (the audio on disk) from the last segment write to `now`. Other phases, an unknown
    /// write date, or one not before `now` leave the session unchanged.
    public static func addingCrashGap(
        to session: RecordingSession, recorded: TimeInterval, lastSegmentModified: Date?, now: Date
    ) -> RecordingSession {
        guard session.phase == .recording || session.phase == .finishing, let began = lastSegmentModified, began < now else { return session }
        var s = session
        s.pauses.append(PauseRecord(at: recorded, began: began, ended: now))
        return s
    }

    /// The newest modification date among `segments`.
    public static func lastModified(of segments: [URL]) -> Date? {
        segments.compactMap(modificationDate).max()
    }

    /// The pauses as transcript markers; a pause still open counts as zero length.
    public static func markers(from pauses: [PauseRecord]) -> [TranscriptMarker] {
        pauses.map { .pause(at: $0.at, duration: $0.duration ?? 0) }
    }

    /// `HH:MM:SS`, rounded down to the second.
    public static func timerText(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// The most recently modified `notes*.md` in the folder (the pipeline's latest save).
    public static func latestNotes(in folder: LectureFolder) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("notes") && $0.pathExtension == "md" }
            .max { (modificationDate($0) ?? .distantPast) < (modificationDate($1) ?? .distantPast) }
    }

    /// Read from the file system each time (URL resource values are cached per URL instance).
    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static let log = Logger(subsystem: "de.haick.faden", category: "StopFlow")
}
