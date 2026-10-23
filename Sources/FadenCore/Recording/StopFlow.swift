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
/// "never lose a recording" rule: segments are deleted only once the audio is in the lecture folder.
public enum StopFlow {
    /// Joins `segments` into the `.m4a` at `output` and returns the ones it skipped; see `AudioFinalizer.finalize`.
    public typealias Finalize = @Sendable (_ segments: [URL], _ output: URL) async throws -> [URL]

    public struct Outcome: Sendable, Equatable {
        public let folder: LectureFolder
        /// The folder name is the `"Lecture HH-mm"` placeholder, not a slide title. For a continued lecture,
        /// what its saved state says (false when it has none).
        public let titleIsPlaceholder: Bool
        /// The saved audio of this part: `audio.m4a` in a new lecture, the next free `audio-N.m4a` in a continued one.
        public let audio: URL
        /// Where the segments the finaliser skipped now are: in the lecture's `.faden/damaged/`, or still in
        /// the segment directory if moving them failed. Empty when every segment was used.
        public let damaged: [URL]
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
    /// A session that continues a lecture (`lectureFolder`) saves into that folder instead, as its next part
    /// (`audio-2.m4a`, `audio-3.m4a`, ...); no earlier part is ever overwritten. If that folder no longer
    /// exists, a new lecture is created as for any other session, so the audio is never lost.
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
        let skipped: [URL]
        do {
            skipped = try await finalize(segments, temp)
        } catch AudioFinalizer.FinalizeError.noSegments where recordedDuration(of: segments) == 0 {
            throw StopFlowError.unreadableAudio(dir: store.dir)
        }
        guard fm.fileExists(atPath: temp.path) else { throw StopFlowError.noFinalAudio }

        let folder: LectureFolder
        let isPlaceholder: Bool
        if let existing = session.lectureFolder, fm.fileExists(atPath: existing.path) {
            folder = LectureFolder(url: existing)
            isPlaceholder = PipelineState.saved(in: folder)?.titleIsPlaceholder ?? false
        } else {
            let (title, placeholder) = title(slides: slides, startedAt: session.startedAt)
            folder = try LectureFolder.create(in: session.courseFolder, date: session.startedAt, title: title)
            isPlaceholder = placeholder
        }
        // `moveItem` never replaces an existing file, and `nextAudioURL` names a free one.
        let audio = folder.nextAudioURL()
        try fm.moveItem(at: temp, to: audio)
        guard fm.fileExists(atPath: audio.path) else { throw StopFlowError.audioNotDelivered }

        // Skipped segments may still hold audio: keep them with the lecture. If any can't be moved, the
        // segment directory isn't deleted.
        let damaged = keepSkipped(skipped, in: folder)
        let allMoved = damaged.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL
            == folder.damagedURL.standardizedFileURL }

        // The audio is safe. Mark the session stopped first, so a failed delete can't bring it back
        // as "unfinished" on the next launch.
        var stopped = session
        stopped.stop()
        do {
            try store.save(stopped)
            if allMoved { try store.discard() }
        } catch {
            log.error("Cleaning up the segments of \(session.id) failed: \(error)")
        }
        return Outcome(folder: folder, titleIsPlaceholder: isPlaceholder, audio: audio, damaged: damaged)
    }

    /// Moves each skipped segment into `folder.damagedURL` and returns where each one is now; a segment
    /// that can't be moved stays (and is listed) where it was. Nothing is deleted or overwritten.
    private static func keepSkipped(_ skipped: [URL], in folder: LectureFolder) -> [URL] {
        guard !skipped.isEmpty else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.damagedURL, withIntermediateDirectories: true)
        return skipped.map { url in
            let target = uniqueDamagedURL(for: url, in: folder)
            do {
                try fm.moveItem(at: url, to: target)
                return target
            } catch {
                log.error("Keeping the unreadable segment \(url.lastPathComponent) failed: \(error)")
                return url
            }
        }
    }

    /// `seg-0001.caf` in the lecture's damaged folder, or `seg-0001 (2).caf`, ... when an earlier part kept one
    /// of that name.
    private static func uniqueDamagedURL(for segment: URL, in folder: LectureFolder) -> URL {
        let base = segment.deletingPathExtension().lastPathComponent
        let ext = segment.pathExtension
        var candidate = folder.damagedURL.appendingPathComponent(segment.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.damagedURL.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
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
