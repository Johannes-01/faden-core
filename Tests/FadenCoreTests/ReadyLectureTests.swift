import Foundation
import Testing
@testable import FadenCore

/// Stop saves the audio only; a lecture is then ready to process, may get more parts, and is processed on demand.
@Suite struct ReadyLectureTests {
    struct Env {
        let root: URL
        let course: URL

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func lectureFolders() -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: course, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
        }

        func store() -> SegmentStore {
            SegmentStore(root: root.appendingPathComponent("recordings", isDirectory: true), sessionID: UUID())
        }
    }

    /// 2026-10-23 09:15 local time.
    static let startedAt: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 23, 9, 15)
        return Calendar.current.date(from: c)!
    }()

    private func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-ready-\(UUID().uuidString)", isDirectory: true)
        let course = root.appendingPathComponent("Course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        return Env(root: root, course: course)
    }

    private static let fakeFinalize: StopFlow.Finalize = { segments, output in
        try Data(segments.map(\.lastPathComponent).joined(separator: ",").utf8).write(to: output)
        return []
    }

    /// Records `segments` fake segments for a session and returns it with its store.
    private func record(_ env: Env, lecture: URL? = nil, segments: Int = 1) throws -> (RecordingSession, SegmentStore) {
        let store = env.store()
        for i in 0..<segments { try Data("segment \(i)".utf8).write(to: store.nextSegmentURL()) }
        let session = RecordingSession(startedAt: Self.startedAt, phase: .finishing, courseFolder: env.course,
                                       lectureFolder: lecture)
        try store.save(session)
        return (session, store)
    }

    private func addPart(_ outcome: StopFlow.Outcome, pauses: [TranscriptMarker] = [], slides: [URL] = [],
                         notes: URL? = nil) throws -> ReadyLecture {
        try ReadyLecture.addingPart(
            outcome.audio, pauses: pauses, to: outcome.folder, slides: slides, userNotes: notes,
            styleID: "C-red-line", allowAdditions: true, language: nil,
            titleIsPlaceholder: outcome.titleIsPlaceholder, now: Self.startedAt)
    }

    // MARK: - Part naming

    @Test func partsAreNamedAudioThenAudioTwoThreeAndNeverOverwritten() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "L")
        #expect(folder.nextAudioURL().lastPathComponent == "audio.m4a")
        try Data("1".utf8).write(to: folder.audioURL)
        #expect(folder.nextAudioURL().lastPathComponent == "audio-2.m4a")
        try Data("2".utf8).write(to: folder.nextAudioURL())
        #expect(folder.nextAudioURL().lastPathComponent == "audio-3.m4a")
        // A gap in the numbering never leads back to an earlier name.
        try Data("10".utf8).write(to: folder.url.appendingPathComponent("audio-10.m4a"))
        #expect(folder.nextAudioURL().lastPathComponent == "audio-11.m4a")
        #expect(folder.audioPartURLs().map(\.lastPathComponent) == ["audio.m4a", "audio-2.m4a", "audio-10.m4a"])
    }

    // MARK: - Stop

    @Test func continuedPartGoesToTheSameLectureAsTheNextPart() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let (first, firstStore) = try record(env, segments: 2)
        let one = try await StopFlow.finish(session: first, slides: [], store: firstStore, finalize: Self.fakeFinalize)
        #expect(one.audio == one.folder.audioURL)
        let firstAudio = try Data(contentsOf: one.folder.audioURL)

        let (second, secondStore) = try record(env, lecture: one.folder.url, segments: 1)
        let two = try await StopFlow.finish(session: second, slides: [], store: secondStore, finalize: Self.fakeFinalize)

        #expect(two.folder == one.folder)
        #expect(two.audio.lastPathComponent == "audio-2.m4a")
        #expect(try Data(contentsOf: one.folder.audioURL) == firstAudio)
        #expect(try String(contentsOf: two.audio, encoding: .utf8) == "seg-0001.caf")
        #expect(env.lectureFolders().count == 1)
        #expect(!FileManager.default.fileExists(atPath: secondStore.dir.path))
    }

    @Test func skippedSegmentsOfTwoPartsAreBothKept() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        // Both parts' first segment is unreadable; both are named seg-0001.caf.
        let skipFirst: StopFlow.Finalize = { segments, output in
            try Data(segments.dropFirst().map(\.lastPathComponent).joined(separator: ",").utf8).write(to: output)
            return [segments[0]]
        }
        let (first, firstStore) = try record(env, segments: 2)
        let one = try await StopFlow.finish(session: first, slides: [], store: firstStore, finalize: skipFirst)
        let (second, secondStore) = try record(env, lecture: one.folder.url, segments: 2)
        let two = try await StopFlow.finish(session: second, slides: [], store: secondStore, finalize: skipFirst)

        #expect(one.damaged.map(\.lastPathComponent) == ["seg-0001.caf"])
        #expect(two.damaged.map(\.lastPathComponent) == ["seg-0001 (2).caf"])
        #expect(two.damaged.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL
            == one.folder.damagedURL.standardizedFileURL })
        #expect(try String(contentsOf: one.damaged[0], encoding: .utf8) == "segment 0")
        #expect(!FileManager.default.fileExists(atPath: secondStore.dir.path))
    }

    @Test func continuedPartOfADeletedLectureStartsANewOne() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let gone = env.course.appendingPathComponent("2026-10-23 Gone", isDirectory: true)
        let (session, store) = try record(env, lecture: gone)

        let outcome = try await StopFlow.finish(session: session, slides: [], store: store, finalize: Self.fakeFinalize)

        #expect(outcome.folder.url.lastPathComponent == "2026-10-23 Lecture 09-15")
        #expect(outcome.titleIsPlaceholder)
        #expect(outcome.audio == outcome.folder.audioURL)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func oldSessionFilesHaveNoLecture() throws {
        let json = """
        {"courseFolder":"file:///tmp/Course/","id":"\(UUID().uuidString)","pauses":[],"phase":"finishing",
         "segmentCount":1,"slides":[],"startedAt":"2026-10-23T07:15:00.000Z"}
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("faden-old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appendingPathComponent("session.json"))
        let session = try SegmentStore.load(dir: root)
        #expect(session.lectureFolder == nil)
        #expect(session.phase == .finishing)
    }

    @Test func aSessionKeepsItsLectureAcrossASave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("faden-lec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = RecordingSession(courseFolder: URL(fileURLWithPath: "/tmp/Course"),
                                 lectureFolder: URL(fileURLWithPath: "/tmp/Course/2026-10-23 L", isDirectory: true))
        let store = SegmentStore(root: root, sessionID: s.id)
        try store.save(s)
        #expect(try SegmentStore.load(dir: store.dir).lectureFolder == s.lectureFolder)
    }

    // MARK: - Ready state

    @Test func stoppedPartsAreSavedAsReadyToProcess() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let (first, firstStore) = try record(env)
        let one = try await StopFlow.finish(session: first, slides: [], store: firstStore, finalize: Self.fakeFinalize)
        let notes = env.root.appendingPathComponent("mine.md")
        let ready = try addPart(one, pauses: [.pause(at: 10, duration: 5)], notes: notes)

        #expect(ready.state.stage == .ready)
        #expect(ready.state.audio == [one.folder.audioURL])
        #expect(ready.state.userNotes == notes)
        #expect(ready.partCount == 1)
        #expect(ReadyLecture.load(one.folder) == ready)

        let (second, secondStore) = try record(env, lecture: one.folder.url)
        let two = try await StopFlow.finish(session: second, slides: [], store: secondStore, finalize: Self.fakeFinalize)
        let both = try addPart(two, pauses: [.pause(at: 3, duration: 2)], notes: notes)

        #expect(both.partCount == 2)
        #expect(both.state.audio.map(\.lastPathComponent) == ["audio.m4a", "audio-2.m4a"])
        #expect(both.state.parts?.map(\.pauses) == [[.pause(at: 10, duration: 5)], [.pause(at: 3, duration: 2)]])
        #expect(ReadyLecture.load(one.folder) == both)
    }

    @Test func aProcessedLectureIsNotReady() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "Done")
        var state = PipelineState(audio: [folder.audioURL], styleID: "C-red-line", allowAdditions: true)
        state.stage = .done
        try FileManager.default.createDirectory(at: folder.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: folder.stateURL)
        #expect(ReadyLecture.load(folder) == nil)
    }

    @Test func processingCombinesThePartsWithPausesOnTheJoinedTimeline() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "Combined")
        let urls = [folder.audioURL, folder.url.appendingPathComponent("audio-2.m4a"),
                    folder.url.appendingPathComponent("audio-3.m4a")]
        for url in urls { try Data("a".utf8).write(to: url) }
        let slide = env.root.appendingPathComponent("Slides.pdf")
        let notes = env.root.appendingPathComponent("mine.md")
        var ready = try ReadyLecture.addingPart(
            urls[0], pauses: [.pause(at: 100, duration: 30)], to: folder, slides: [slide], userNotes: notes,
            styleID: "A-slide-by-slide", allowAdditions: false, language: "de", titleIsPlaceholder: false, now: Self.startedAt)
        ready = try ReadyLecture.addingPart(
            urls[1], pauses: [], to: folder, slides: [slide], userNotes: notes,
            styleID: "A-slide-by-slide", allowAdditions: false, language: "de", titleIsPlaceholder: false, now: Self.startedAt)
        ready = try ReadyLecture.addingPart(
            urls[2], pauses: [.pause(at: 5, duration: 60), .pause(at: 50, duration: 1)], to: folder, slides: [slide],
            userNotes: notes, styleID: "A-slide-by-slide", allowAdditions: false, language: "de",
            titleIsPlaceholder: false, now: Self.startedAt)

        let durations: [String: TimeInterval] = ["audio.m4a": 600, "audio-2.m4a": 1200.5, "audio-3.m4a": 30]
        let state = try await ready.processingState(
            styleID: "C-red-line", allowAdditions: true, language: "en",
            duration: { durations[$0.lastPathComponent]! })

        #expect(state.stage == .transcribing)
        #expect(state.audio == urls)
        #expect(state.slides == [slide])
        #expect(state.userNotes == notes)
        #expect(state.styleID == "C-red-line")
        #expect(state.allowAdditions)
        #expect(state.language == "en")
        #expect(!state.titleIsPlaceholder)
        #expect(state.markers == [.pause(at: 100, duration: 30), .pause(at: 1805.5, duration: 60),
                                  .pause(at: 1850.5, duration: 1)])
        #expect(ReadyLecture.totalDuration(durations: [600, 1200.5, 30]) == 1830.5)
    }

    @Test func processingADeletedPartSaysSo() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "Gone part")
        try Data("a".utf8).write(to: folder.audioURL)
        let ready = try ReadyLecture.addingPart(
            folder.audioURL, pauses: [], to: folder, slides: [], userNotes: nil, styleID: "C-red-line",
            allowAdditions: true, language: nil, titleIsPlaceholder: true, now: Self.startedAt)
        try FileManager.default.removeItem(at: folder.audioURL)

        await #expect(throws: ReadyLectureError.deleted("audio.m4a")) {
            _ = try await ready.processingState(styleID: "C-red-line", allowAdditions: true, language: nil,
                                                duration: { _ in 1 })
        }
    }

    @Test func firstSlideDuringReviewRenamesAPlaceholderFolder() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let (session, store) = try record(env)
        let outcome = try await StopFlow.finish(session: session, slides: [], store: store, finalize: Self.fakeFinalize)
        #expect(outcome.titleIsPlaceholder)
        var ready = try addPart(outcome)

        let slide = env.root.appendingPathComponent("Eigen_values.pdf")
        try ready.setAttachments(slides: [slide], userNotes: nil, now: Self.startedAt)

        #expect(ready.folder.url.lastPathComponent == "2026-10-23 Eigen values")
        #expect(!ready.state.titleIsPlaceholder)
        #expect(ready.state.slides == [slide])
        #expect(ready.state.audio == [ready.folder.audioURL])
        #expect(FileManager.default.fileExists(atPath: ready.folder.audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: outcome.folder.url.path))
        #expect(ReadyLecture.load(ready.folder) == ready)

        // A titled folder isn't renamed again by later slide changes.
        try ready.setAttachments(slides: [env.root.appendingPathComponent("Other.pdf"), slide], userNotes: nil,
                                 now: Self.startedAt)
        #expect(ready.folder.url.lastPathComponent == "2026-10-23 Eigen values")
    }

    @Test func slidesOnATitledLectureDontRenameIt() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "Kept")
        try Data("a".utf8).write(to: folder.audioURL)
        var ready = try ReadyLecture.addingPart(
            folder.audioURL, pauses: [], to: folder, slides: [], userNotes: nil, styleID: "C-red-line",
            allowAdditions: true, language: nil, titleIsPlaceholder: false, now: Self.startedAt)
        let notes = env.root.appendingPathComponent("mine.md")
        try ready.setAttachments(slides: [env.root.appendingPathComponent("New_title.pdf")], userNotes: notes,
                                 now: Self.startedAt)
        #expect(ready.folder == folder)
        #expect(ReadyLecture.load(folder)?.state.userNotes == notes)
    }

    @Test func partsOnDiskButNotListedAreFoundIncludedAndBlockProcessing() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "Unlisted")
        let names = ["audio.m4a", "audio-2.m4a", "audio-3.m4a", "audio-10.m4a"]
        for name in names { try Data("a".utf8).write(to: folder.url.appendingPathComponent(name)) }
        var ready = try ReadyLecture.addingPart(
            folder.audioURL, pauses: [.pause(at: 1, duration: 1)], to: folder, slides: [], userNotes: nil,
            styleID: "C-red-line", allowAdditions: true, language: nil, titleIsPlaceholder: false, now: Self.startedAt)
        ready = try ReadyLecture.addingPart(
            folder.url.appendingPathComponent("audio-3.m4a"), pauses: [.pause(at: 2, duration: 1)], to: folder,
            slides: [], userNotes: nil, styleID: "C-red-line", allowAdditions: true, language: nil,
            titleIsPlaceholder: false, now: Self.startedAt)
        // Saved by Stop, but never recorded in the state (e.g. saving the state failed).
        #expect(ready.unlistedParts().map(\.lastPathComponent) == ["audio-2.m4a", "audio-10.m4a"])

        await #expect(throws: ReadyLectureError.unlisted(["audio-2.m4a", "audio-10.m4a"])) {
            _ = try await ready.processingState(styleID: "C-red-line", allowAdditions: true, language: nil,
                                                duration: { _ in 1 })
        }

        try ready.include(ready.unlistedParts())
        #expect(ready.unlistedParts().isEmpty)
        #expect(ready.parts.map(\.file) == names)
        #expect(ReadyLecture.load(folder) == ready)
        let durations: [String: TimeInterval] = ["audio.m4a": 10, "audio-2.m4a": 20, "audio-3.m4a": 30, "audio-10.m4a": 5]
        let state = try await ready.processingState(styleID: "C-red-line", allowAdditions: true, language: nil,
                                                    duration: { durations[$0.lastPathComponent]! })
        #expect(state.audio.map(\.lastPathComponent) == names)
        #expect(state.markers == [.pause(at: 1, duration: 1), .pause(at: 32, duration: 1)])
    }

    // MARK: - Run board

    @Test func readyLecturesAreRestoredAndDeletedOnesDropped() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let (a, aStore) = try record(env)
        let first = try await StopFlow.finish(session: a, slides: [URL(fileURLWithPath: "/x/Kept.pdf")], store: aStore,
                                              finalize: Self.fakeFinalize)
        let kept = try addPart(first)
        let (b, bStore) = try record(env)
        let second = try await StopFlow.finish(session: b, slides: [URL(fileURLWithPath: "/x/Deleted.pdf")],
                                               store: bStore, finalize: Self.fakeFinalize)
        let deleted = try addPart(second)

        var board = RunBoard()
        board.ready(deleted.folder)
        board.ready(kept.folder)
        #expect(board.runs.map(\.stage) == [.ready, .ready])
        #expect(board.unfinishedPaths == [kept.folder.url.path, deleted.folder.url.path])

        try FileManager.default.removeItem(at: deleted.folder.url)
        let restored = RunBoard.restored(paths: board.unfinishedPaths)
        #expect(restored.runs.map(\.folder) == [kept.folder])
        #expect(restored.runs[0].stage == .ready)
        #expect(restored.runs[0].error == nil)
        #expect(!restored.runs[0].isRunning)
        #expect(restored.visible.count == 1)

        board.noticeDeletedFiles { FileManager.default.fileExists(atPath: $0.path) }
        #expect(board.runs.map(\.folder) == [kept.folder])
    }

    @Test func aRenamedReadyLectureReplacesItsEntry() {
        let old = LectureFolder(url: URL(fileURLWithPath: "/c/2026-10-23 Lecture 09-15", isDirectory: true))
        let new = LectureFolder(url: URL(fileURLWithPath: "/c/2026-10-23 Title", isDirectory: true))
        var board = RunBoard()
        board.ready(old)
        board.ready(new, replacing: old, error: nil)
        #expect(board.runs.map(\.folder) == [new])
        board.ready(new, error: "Can't process")
        #expect(board.runs.count == 1)
        #expect(board.runs[0].error == "Can't process")
        let id = board.runs[0].id
        board.dismiss(id)
        #expect(board.runs.isEmpty)
    }

    // MARK: - Pipeline

    @Test func readyIsNothingToResume() {
        var state = PipelineState(stage: .ready, audio: [], styleID: "C-red-line", allowAdditions: true)
        #expect(state.resumeStage == nil)
        state.stage = .transcribing
        #expect(state.resumeStage == .transcribing)
    }

    @Test func oldStateFilesStillDecode() throws {
        let json = #"{"stage":"verifying","audio":[],"slides":[],"styleID":"C","allowAdditions":true,"#
            + #""transcriptionModel":"m","forceRetranscribe":false,"titleIsPlaceholder":false,"markers":[]}"#
        let state = try JSONDecoder().decode(PipelineState.self, from: Data(json.utf8))
        #expect(state.stage == .verifying)
        #expect(state.parts == nil)
    }

    @Test func retryLeavesAReadyLectureAloneAndRunStartsAtTranscribing() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folder = try LectureFolder.create(in: env.course, date: Self.startedAt, title: "Ready")
        try Data("a".utf8).write(to: folder.audioURL)
        let ready = try ReadyLecture.addingPart(
            folder.audioURL, pauses: [], to: folder, slides: [], userNotes: nil, styleID: "C-red-line",
            allowAdditions: true, language: nil, titleIsPlaceholder: false, now: Self.startedAt)
        let styles = StyleStore(dir: env.root.appendingPathComponent("styles", isDirectory: true))
        try styles.installDefaultsIfMissing()
        let transcriber = FakeTranscriber()
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let pipeline = Pipeline(folder: folder, transcriber: transcriber, client: client, styles: styles,
                                ledger: CostLedger(file: env.root.appendingPathComponent("costs.jsonl")),
                                now: { Self.startedAt }, duration: { _ in 60 })

        let retried = await pipeline.retry()
        #expect(retried.stage == .ready)
        #expect(await transcriber.calls == 0)
        #expect(await client.calls == 0)

        let ran = await pipeline.run(ready.state)
        #expect(ran.stage == .done)
        #expect(await transcriber.calls == 1)
    }
}
