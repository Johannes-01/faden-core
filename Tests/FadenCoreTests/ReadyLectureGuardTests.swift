import Foundation
import Testing
@testable import FadenCore

/// A ready lecture is never written once something else (e.g. Process again) has taken its state over, and
/// Process again on a ready lecture keeps its pauses and waits for anything else working on it.
@Suite struct ReadyLectureGuardTests {
    static let now: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 23, 9, 15)
        return Calendar.current.date(from: c)!
    }()

    private func makeCourse() throws -> URL {
        let course = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        return course
    }

    private func ready(in course: URL, title: String = "Lecture 09-15", placeholder: Bool = true,
                       files: [String] = ["audio.m4a"], pauses: [[TranscriptMarker]]? = nil) throws -> ReadyLecture {
        let folder = try LectureFolder.create(in: course, date: Self.now, title: title)
        var lecture: ReadyLecture?
        for (i, name) in files.enumerated() {
            let url = folder.url.appendingPathComponent(name)
            try Data("a".utf8).write(to: url)
            lecture = try ReadyLecture.addingPart(
                url, pauses: pauses?[i] ?? [], to: folder, slides: [], userNotes: nil, styleID: "C-red-line",
                allowAdditions: true, language: nil, titleIsPlaceholder: placeholder, now: Self.now)
        }
        return try #require(lecture)
    }

    /// Writes `stage` over the lecture's state, as a run started by Process again would.
    private func takeOver(_ lecture: ReadyLecture, stage: Stage) throws -> Data {
        var state = lecture.state
        state.stage = stage
        state.parts = nil
        state.notesCall = PaidCall(model: "claude-opus-5-5", usage: Usage(inputTokens: 1, outputTokens: 1))
        let data = try JSONEncoder().encode(state)
        try data.write(to: lecture.folder.stateURL)
        return data
    }

    // MARK: - Item 1: the backstop

    @Test func editsRefuseALectureThatIsNoLongerReady() throws {
        let course = try makeCourse()
        defer { try? FileManager.default.removeItem(at: course) }
        var lecture = try ready(in: course, files: ["audio.m4a", "audio-2.m4a"])
        try FileManager.default.removeItem(at: lecture.folder.url.appendingPathComponent("audio-2.m4a"))
        try Data("b".utf8).write(to: lecture.folder.url.appendingPathComponent("audio-3.m4a"))
        let folderName = lecture.folder.url.lastPathComponent

        for stage in [Stage.transcribing, .writingNotes, .done, .failed] {
            let written = try takeOver(lecture, stage: stage)
            #expect(throws: ReadyLectureError.notReady) {
                try lecture.setAttachments(slides: [course.appendingPathComponent("New_title.pdf")], userNotes: nil,
                                           now: Self.now)
            }
            #expect(throws: ReadyLectureError.notReady) {
                try lecture.include(lecture.unlistedParts())
            }
            // Nothing written, nothing renamed under the run.
            #expect(try Data(contentsOf: lecture.folder.stateURL) == written)
            #expect(lecture.folder.url.lastPathComponent == folderName)
            #expect(FileManager.default.fileExists(atPath: lecture.folder.url.path))
        }
    }

    @Test func aPartIsNotAddedOverARunInProgress() throws {
        let course = try makeCourse()
        defer { try? FileManager.default.removeItem(at: course) }
        let lecture = try ready(in: course)
        let written = try takeOver(lecture, stage: .verifying)
        let part = lecture.folder.url.appendingPathComponent("audio-2.m4a")
        try Data("b".utf8).write(to: part)
        #expect(throws: ReadyLectureError.notReady) {
            _ = try ReadyLecture.addingPart(
                part, pauses: [], to: lecture.folder, slides: [], userNotes: nil, styleID: "C-red-line",
                allowAdditions: true, language: nil, titleIsPlaceholder: true, now: Self.now)
        }
        #expect(try Data(contentsOf: lecture.folder.stateURL) == written)
    }

    // MARK: - Item 4: a part after one without a ready state

    @Test func aPartAfterAnUnlistedFirstPartListsItWithoutPauses() throws {
        let course = try makeCourse()
        defer { try? FileManager.default.removeItem(at: course) }
        let folder = try LectureFolder.create(in: course, date: Self.now, title: "Recovered")
        try Data("a".utf8).write(to: folder.audioURL)
        let second = folder.url.appendingPathComponent("audio-2.m4a")
        try Data("b".utf8).write(to: second)

        let lecture = try ReadyLecture.addingPart(
            second, pauses: [.pause(at: 4, duration: 2)], to: folder, slides: [], userNotes: nil,
            styleID: "C-red-line", allowAdditions: true, language: nil, titleIsPlaceholder: false, now: Self.now)

        #expect(lecture.parts == [RecordedPart(file: "audio.m4a", pauses: []),
                                  RecordedPart(file: "audio-2.m4a", pauses: [.pause(at: 4, duration: 2)])])
        #expect(lecture.state.audio == [folder.audioURL, second])
        #expect(lecture.unlistedParts().isEmpty)
    }

    // MARK: - Item 1: the gate for Process again

    @Test func processAgainWaitsForAnythingElseOnTheLecture() {
        let free = ReviewGate(recorderIdle: true, isFinishing: false, isStarting: false, isPreparingProcess: false,
                              isRunning: false, isRecordingInto: false, hasUnlistedParts: false)
        #expect(free.canReprocess)
        func with(_ change: (inout ReviewGate) -> Void) -> ReviewGate { var g = free; change(&g); return g }
        #expect(!with { $0.isStarting = true }.canReprocess)
        #expect(!with { $0.isFinishing = true }.canReprocess)
        #expect(!with { $0.isPreparingProcess = true }.canReprocess)
        #expect(!with { $0.isRunning = true }.canReprocess)
        #expect(!with { $0.recorderIdle = false; $0.isRecordingInto = true }.canReprocess)
        // Recording another lecture, or unlisted parts the user didn't pick, don't block it.
        #expect(with { $0.recorderIdle = false }.canReprocess)
        #expect(with { $0.hasUnlistedParts = true }.canReprocess)
    }

    @Test func processAgainTargetsTheLectureFolderItWouldReuse() throws {
        let course = try makeCourse()
        defer { try? FileManager.default.removeItem(at: course) }
        let lecture = try ready(in: course, files: ["audio.m4a", "audio-2.m4a"])
        func request(_ recordings: [URL], course: URL) -> ReprocessRequest {
            ReprocessRequest(recordings: recordings, courseFolder: course, slides: [], userNotes: nil,
                             styleID: "C-red-line", allowAdditions: true, language: nil, forceRetranscribe: false)
        }
        #expect(ReprocessPlanner.targetFolder(request(lecture.audio, course: course)) == lecture.folder)
        // In another course folder, or outside any lecture, a new lecture is made instead.
        #expect(ReprocessPlanner.targetFolder(request(lecture.audio, course: course.appendingPathComponent("x"))) == nil)
        let loose = course.appendingPathComponent("loose.m4a")
        try Data("c".utf8).write(to: loose)
        #expect(ReprocessPlanner.targetFolder(request([loose], course: course)) == nil)
        #expect(ReprocessPlanner.targetFolder(request([], course: course)) == nil)
        let plan = try ReprocessPlanner.plan(request(lecture.audio, course: course), now: Self.now)
        #expect(plan.folder == lecture.folder)
    }

    // MARK: - Item 2: Process again keeps the ready lecture's pauses

    @Test func processAgainOnAReadyLectureKeepsItsPauses() async throws {
        let course = try makeCourse()
        defer { try? FileManager.default.removeItem(at: course) }
        let lecture = try ready(in: course, files: ["audio.m4a", "audio-2.m4a"],
                                pauses: [[.pause(at: 10, duration: 5)], [.pause(at: 3, duration: 2)]])
        let durations: [String: TimeInterval] = ["audio.m4a": 100, "audio-2.m4a": 50]
        let markers = try await lecture.markers(forRecordings: lecture.audio,
                                                duration: { durations[$0.lastPathComponent]! })
        #expect(markers == [.pause(at: 10, duration: 5), .pause(at: 103, duration: 2)])

        // Other recordings, or the same ones in another order, don't carry the pauses.
        #expect(try await lecture.markers(forRecordings: [lecture.audio[0]], duration: { _ in 1 }) == nil)
        #expect(try await lecture.markers(forRecordings: lecture.audio.reversed(), duration: { _ in 1 }) == nil)

        var request = ReprocessRequest(recordings: lecture.audio, courseFolder: course, slides: [], userNotes: nil,
                                       styleID: "C-red-line", allowAdditions: true, language: nil,
                                       forceRetranscribe: false)
        request.markers = markers
        let plan = try ReprocessPlanner.plan(request, now: Self.now)
        #expect(plan.state.markers == markers)
        #expect(plan.state.stage == .transcribing)
    }
}
