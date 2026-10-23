import Foundation
import Testing
@testable import FadenCore

@Suite struct StopFlowTests {
    struct Env {
        let root: URL
        let course: URL
        let store: SegmentStore

        func cleanup() {
            // Restore permissions a test may have removed, so the temp tree can be cleaned up.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: course.path)
            try? FileManager.default.removeItem(at: root)
        }

        func lectureFolders() -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: course, includingPropertiesForKeys: nil)) ?? []
        }
    }

    /// 2026-10-23 09:15 local time.
    static let startedAt: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 23, 9, 15)
        return Calendar.current.date(from: c)!
    }()

    private func makeEnv(segments: Int = 2) throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-stopflow-\(UUID().uuidString)", isDirectory: true)
        let course = root.appendingPathComponent("Course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        let store = SegmentStore(root: root.appendingPathComponent("recordings", isDirectory: true), sessionID: UUID())
        for i in 0..<segments {
            try Data("segment \(i)".utf8).write(to: store.nextSegmentURL())
        }
        return Env(root: root, course: course, store: store)
    }

    private func makeSession(_ env: Env, phase: RecordingPhase = .stopped) throws -> RecordingSession {
        let session = RecordingSession(startedAt: Self.startedAt, phase: phase, courseFolder: env.course)
        try env.store.save(session)
        return session
    }

    /// Writes the segment names into `output`, like a real export would produce a file.
    private static let fakeFinalize: StopFlow.Finalize = { segments, output in
        try Data(segments.map(\.lastPathComponent).joined(separator: ",").utf8).write(to: output)
    }

    private func tempAudio(in store: SegmentStore) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: store.dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
    }

    // MARK: - Titles

    @Test func placeholderTitleUsesStartTime() {
        #expect(StopFlow.placeholderTitle(startedAt: Self.startedAt) == "Lecture 09-15")
    }

    @Test func titleComesFromFirstSlide() {
        let slides = [URL(fileURLWithPath: "/x/Linear_Algebra 3.pdf"), URL(fileURLWithPath: "/x/Other.pdf")]
        let t = StopFlow.title(slides: slides, startedAt: Self.startedAt)
        #expect(t.title == "Linear Algebra 3")
        #expect(!t.isPlaceholder)
    }

    @Test func titleFallsBackToPlaceholder() {
        let t = StopFlow.title(slides: [], startedAt: Self.startedAt)
        #expect(t.title == "Lecture 09-15")
        #expect(t.isPlaceholder)
    }

    // MARK: - Stop flow

    @Test func finishMovesAudioIntoNewFolderThenDeletesSegments() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let session = try makeSession(env)

        let result = try await StopFlow.finish(
            session: session, slides: [URL(fileURLWithPath: "/x/Eigen_values.pdf")], store: env.store,
            finalize: Self.fakeFinalize)

        #expect(result.folder.url.lastPathComponent == "2026-10-23 Eigen values")
        #expect(result.folder.url.deletingLastPathComponent().standardizedFileURL == env.course.standardizedFileURL)
        #expect(!result.titleIsPlaceholder)
        let audio = try String(contentsOf: result.folder.audioURL, encoding: .utf8)
        #expect(audio == "seg-0001.caf,seg-0002.caf")
        #expect(!FileManager.default.fileExists(atPath: env.store.dir.path))
    }

    @Test func finishWithoutSlidesUsesPlaceholder() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let result = try await StopFlow.finish(
            session: try makeSession(env), slides: [], store: env.store, finalize: Self.fakeFinalize)
        #expect(result.folder.url.lastPathComponent == "2026-10-23 Lecture 09-15")
        #expect(result.titleIsPlaceholder)
    }

    @Test func finishMarksARecoveredSessionStoppedBeforeDeleting() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        // A recovered session is still `.recording` on disk; it must not come back after the stop.
        let session = try makeSession(env, phase: .recording)
        _ = try await StopFlow.finish(session: session, slides: [], store: env.store, finalize: Self.fakeFinalize)
        #expect(SegmentStore.unfinished(root: env.store.dir.deletingLastPathComponent()).isEmpty)
    }

    @Test func finaliseFailureKeepsSegmentsAndCreatesNoFolder() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let session = try makeSession(env)
        struct Boom: Error {}

        await #expect(throws: Boom.self) {
            try await StopFlow.finish(session: session, slides: [], store: env.store) { _, _ in throw Boom() }
        }

        #expect(env.store.segments().count == 2)
        #expect(FileManager.default.fileExists(atPath: env.store.dir.appendingPathComponent("session.json").path))
        #expect(env.lectureFolders().isEmpty)
    }

    @Test func folderFailureKeepsSegmentsAndTempAudio() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let session = try makeSession(env)
        // A read-only course folder: the lecture folder can't be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.course.path)

        await #expect(throws: (any Error).self) {
            try await StopFlow.finish(session: session, slides: [], store: env.store, finalize: Self.fakeFinalize)
        }

        #expect(env.store.segments().count == 2)
        let temp = tempAudio(in: env.store)
        #expect(temp.count == 1)
        #expect(try String(contentsOf: temp[0], encoding: .utf8) == "seg-0001.caf,seg-0002.caf")
    }

    @Test func retryAfterFailureLeavesEarlierTempAudioAlone() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let session = try makeSession(env)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.course.path)
        _ = try? await StopFlow.finish(session: session, slides: [], store: env.store, finalize: Self.fakeFinalize)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.course.path)

        let result = try await StopFlow.finish(
            session: session, slides: [], store: env.store, finalize: Self.fakeFinalize)

        #expect(FileManager.default.fileExists(atPath: result.folder.audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: env.store.dir.path))
    }

    @Test func noSegmentsIsNothingRecorded() async throws {
        let env = try makeEnv(segments: 0)
        defer { env.cleanup() }
        await #expect(throws: StopFlowError.nothingRecorded) {
            try await StopFlow.finish(
                session: try makeSession(env), slides: [], store: env.store, finalize: Self.fakeFinalize)
        }
        #expect(env.lectureFolders().isEmpty)
    }

    @Test func onlyUnreadableSegmentsIsNothingRecordedAndKeepsThem() async throws {
        let env = try makeEnv(segments: 1)  // "segment 0" is not a readable CAF
        defer { env.cleanup() }
        await #expect(throws: StopFlowError.nothingRecorded) {
            try await StopFlow.finish(session: try makeSession(env), slides: [], store: env.store) { _, _ in
                throw AudioFinalizer.FinalizeError.noSegments
            }
        }
        #expect(env.store.segments().count == 1)
    }

    // MARK: - Recovery

    @Test func reopenTurnsAStoppedSessionIntoARecoverablePausedOne() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let now = Self.startedAt.addingTimeInterval(3600)
        let stopped = try makeSession(env)

        let reopened = StopFlow.reopenForRecovery(stopped, at: 120, now: now)
        try env.store.save(reopened)

        #expect(reopened.phase == .paused)
        #expect(reopened.pauses == [PauseRecord(at: 120, began: now)])
        #expect(SegmentStore.unfinished(root: env.store.dir.deletingLastPathComponent()).map(\.id) == [stopped.id])
    }

    @Test func reopenLeavesAnUnfinishedSessionAlone() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let recording = try makeSession(env, phase: .recording)
        #expect(StopFlow.reopenForRecovery(recording, at: 120, now: Date()) == recording)
    }

    @Test func crashGapAddsAClosedPauseForARecordingSession() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let crash = Self.startedAt.addingTimeInterval(600)
        let resume = Self.startedAt.addingTimeInterval(900)
        let session = try makeSession(env, phase: .recording)

        let resumed = StopFlow.addingCrashGap(to: session, recorded: 598.5, lastSegmentModified: crash, now: resume)

        #expect(resumed.pauses == [PauseRecord(at: 598.5, began: crash, ended: resume)])
        #expect(resumed.pauses[0].duration == 300)
        #expect(resumed.phase == .recording)
    }

    @Test func crashGapIgnoresPausedSessionsAndMissingDates() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let paused = try makeSession(env, phase: .paused)
        let recording = try makeSession(env, phase: .recording)
        let crash = Self.startedAt.addingTimeInterval(600)
        // A paused session's open pause already spans the gap.
        #expect(StopFlow.addingCrashGap(to: paused, recorded: 10, lastSegmentModified: crash, now: Date()) == paused)
        #expect(StopFlow.addingCrashGap(to: recording, recorded: 10, lastSegmentModified: nil, now: Date()) == recording)
        // A modification date after "now" (clock change) is no gap.
        #expect(StopFlow.addingCrashGap(to: recording, recorded: 10, lastSegmentModified: crash, now: crash) == recording)
    }

    @Test func lastModifiedIsTheNewestSegment() throws {
        let env = try makeEnv(segments: 3)
        defer { env.cleanup() }
        let segments = env.store.segments()
        let dates = [100.0, 300.0, 200.0].map { Self.startedAt.addingTimeInterval($0) }
        for (url, date) in zip(segments, dates) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        #expect(StopFlow.lastModified(of: segments) == dates[1])
        #expect(StopFlow.lastModified(of: []) == nil)
    }

    // MARK: - Markers, timer, notes

    @Test func pausesBecomePauseMarkers() {
        let began = Self.startedAt
        let pauses = [
            PauseRecord(at: 60, began: began, ended: began.addingTimeInterval(30)),
            PauseRecord(at: 120.5, began: began.addingTimeInterval(100), ended: nil),
        ]
        #expect(StopFlow.markers(from: pauses) == [.pause(at: 60, duration: 30), .pause(at: 120.5, duration: 0)])
    }

    @Test func timerTextIsHoursMinutesSeconds() {
        #expect(StopFlow.timerText(0) == "00:00:00")
        #expect(StopFlow.timerText(59.9) == "00:00:59")
        #expect(StopFlow.timerText(3725) == "01:02:05")
        #expect(StopFlow.timerText(-3) == "00:00:00")
    }

    @Test func latestNotesIsTheNewestNotesFile() throws {
        let env = try makeEnv(segments: 0)
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "L")
        #expect(StopFlow.latestNotes(in: folder) == nil)
        let files = ["notes.md": 100.0, "notes (re-run 2026-10-23 10-00).md": 300.0, "transcript.md": 500.0]
        for (name, offset) in files {
            let url = folder.url.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.startedAt.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }
        #expect(StopFlow.latestNotes(in: folder)?.lastPathComponent == "notes (re-run 2026-10-23 10-00).md")
    }
}

@Suite struct ModelCacheTests {
    @Test func completeOnlyWhenEveryModelFileIsPresent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!ModelCache.isDownloaded(variant: "small", base: base))

        let folder = ModelCache.folder(variant: "small", base: base)
        #expect(folder.path.hasSuffix("models/argmaxinc/whisperkit-coreml/openai_whisper-small"))
        for path in ModelCache.requiredFiles.dropLast() {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        #expect(!ModelCache.isDownloaded(variant: "small", base: base))

        let last = folder.appendingPathComponent(ModelCache.requiredFiles.last!)
        try FileManager.default.createDirectory(at: last.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: last)
        #expect(ModelCache.isDownloaded(variant: "small", base: base))
        #expect(!ModelCache.isDownloaded(variant: "large-v3-v20240930_turbo", base: base))
    }
}

@Suite struct MissingKeyClientTests {
    @Test func pipelineFailsAtNotesWithTheSettingsMessageAndStaysRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-missingkey-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LectureFolder.create(
            in: root.appendingPathComponent("Course", isDirectory: true), date: StopFlowTests.startedAt, title: "L")
        try Data("fake audio".utf8).write(to: folder.audioURL)
        let styles = StyleStore(dir: root.appendingPathComponent("styles", isDirectory: true))
        try styles.installDefaultsIfMissing()
        let ledger = CostLedger(file: root.appendingPathComponent("costs.jsonl"))
        let transcriber = FakeTranscriber()

        let state = await Pipeline(
            folder: folder, transcriber: transcriber, client: MissingKeyClient(), styles: styles,
            ledger: ledger, now: { StopFlowTests.startedAt }, duration: { _ in 60 }
        ).run(PipelineState(audio: [folder.audioURL], styleID: "C-red-line", allowAdditions: true))

        #expect(state.stage == .failed)
        #expect(state.failedStage == .writingNotes)
        #expect(state.error == "Add your Anthropic API key in Settings")

        // With a key, a fresh pipeline's retry resumes at the notes and does not transcribe again.
        let retried = await Pipeline(
            folder: folder, transcriber: transcriber, client: FakeClient([FakeClient.notes(), FakeClient.verify()]),
            styles: styles, ledger: ledger, now: { StopFlowTests.startedAt }, duration: { _ in 60 }
        ).retry()
        #expect(retried.stage == .done)
        #expect(await transcriber.calls == 1)
    }
}
