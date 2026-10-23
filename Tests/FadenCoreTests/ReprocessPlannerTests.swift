import CoreGraphics
import Foundation
import Testing
@testable import FadenCore

@Suite struct ReprocessPlannerTests {
    static let now = Date(timeIntervalSince1970: 1_792_756_800) // 2026-10-23

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-planner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A lecture folder with `audio.m4a` and a `.faden/state.json`.
    private func makeLecture(in course: URL, title: String, placeholder: Bool = false,
                             markers: [TranscriptMarker] = []) throws -> LectureFolder {
        let folder = try LectureFolder.create(in: course, date: Date(timeIntervalSince1970: 1_792_000_000), title: title)
        try Data("audio".utf8).write(to: folder.audioURL)
        var state = PipelineState(audio: [folder.audioURL], styleID: "C-red-line", allowAdditions: true,
                                  titleIsPlaceholder: placeholder, markers: markers)
        state.stage = .done
        try JSONEncoder().encode(state).write(to: folder.stateURL.creatingParent())
        return folder
    }

    private func request(_ recordings: [URL], course: URL, slides: [URL] = [], force: Bool = false) -> ReprocessRequest {
        ReprocessRequest(recordings: recordings, courseFolder: course, slides: slides, userNotes: nil,
                         styleID: "B-by-topic", allowAdditions: false, forceRetranscribe: force)
    }

    private func makePDF(at url: URL, title: String?) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
    }

    @Test func plannerUsesFirstRecordingsFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let lecture = try makeLecture(in: course, title: "Week 3")
        let lectureCount = try FileManager.default.contentsOfDirectory(atPath: course.path).count

        let plan = try ReprocessPlanner.plan(request([lecture.audioURL], course: course, force: true), now: Self.now)

        #expect(plan.folder.url.standardizedFileURL == lecture.url.standardizedFileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: course.path).count == lectureCount)
        #expect(plan.state.audio == [lecture.audioURL])
        #expect(plan.state.stage == .transcribing)
        #expect(plan.state.styleID == "B-by-topic")
        #expect(plan.state.allowAdditions == false)
        #expect(plan.state.forceRetranscribe)
        #expect(plan.state.transcriptionModel == "")
        #expect(plan.state.titleIsPlaceholder == false)
        #expect(plan.state.markers.isEmpty)
    }

    @Test func plannerKeepsPlaceholderOfExistingUnnamedFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let lecture = try makeLecture(in: course, title: "Lecture", placeholder: true)

        let plan = try ReprocessPlanner.plan(request([lecture.audioURL], course: course), now: Self.now)

        #expect(plan.state.titleIsPlaceholder)
    }

    @Test func plannerKeepsPauseMarkersForSameAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let pauses: [TranscriptMarker] = [.pause(at: 600, duration: 300)]
        let lecture = try makeLecture(in: course, title: "Week 3", markers: pauses)

        let same = try ReprocessPlanner.plan(request([lecture.audioURL], course: course, force: true), now: Self.now)
        #expect(same.state.markers == pauses)

        let memo = root.appendingPathComponent("memo.m4a")
        try Data("memo".utf8).write(to: memo)
        let changed = try ReprocessPlanner.plan(request([lecture.audioURL, memo], course: course), now: Self.now)
        #expect(changed.state.markers.isEmpty)
    }

    @Test func plannerCopiesImportedAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let memos = root.appendingPathComponent("Voice Memos", isDirectory: true)
        try FileManager.default.createDirectory(at: memos, withIntermediateDirectories: true)
        let memo1 = memos.appendingPathComponent("New Recording.m4a")
        let memo2 = memos.appendingPathComponent("New Recording 2.mp3")
        try Data("one".utf8).write(to: memo1)
        try Data("two".utf8).write(to: memo2)

        let plan = try ReprocessPlanner.plan(request([memo1, memo2], course: course), now: Self.now)

        #expect(plan.folder.url.deletingLastPathComponent().standardizedFileURL == course.standardizedFileURL)
        #expect(plan.folder.url.lastPathComponent == "2026-10-23 Lecture")
        #expect(plan.state.titleIsPlaceholder)
        let copied1 = plan.folder.url.appendingPathComponent("audio.m4a")
        let copied2 = plan.folder.url.appendingPathComponent("audio-2.mp3")
        #expect(plan.state.audio == [copied1, copied2])
        #expect(try Data(contentsOf: copied1) == Data("one".utf8))
        #expect(try Data(contentsOf: copied2) == Data("two".utf8))
        #expect(FileManager.default.fileExists(atPath: memo1.path))
        #expect(FileManager.default.fileExists(atPath: memo2.path))
    }

    @Test func plannerCopyNeverOverwritesExistingAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let lecture = try makeLecture(in: course, title: "Week 3")
        let memo = root.appendingPathComponent("memo.m4a")
        try Data("memo".utf8).write(to: memo)

        let plan = try ReprocessPlanner.plan(request([lecture.audioURL, memo], course: course), now: Self.now)

        let copied = lecture.url.appendingPathComponent("audio-2.m4a")
        #expect(plan.state.audio == [lecture.audioURL, copied])
        #expect(try Data(contentsOf: lecture.audioURL) == Data("audio".utf8))
        #expect(try Data(contentsOf: copied) == Data("memo".utf8))
    }

    @Test func plannerNewFolderForOtherCourse() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let courseA = root.appendingPathComponent("Course A", isDirectory: true)
        let courseB = root.appendingPathComponent("Course B", isDirectory: true)
        let lecture = try makeLecture(in: courseA, title: "Week 3")
        let slide = root.appendingPathComponent("Signals_Week_4.pdf")
        try makePDF(at: slide, title: nil)

        let plan = try ReprocessPlanner.plan(request([lecture.audioURL], course: courseB, slides: [slide]), now: Self.now)

        #expect(plan.folder.url.deletingLastPathComponent().standardizedFileURL == courseB.standardizedFileURL)
        #expect(plan.folder.url.lastPathComponent == "2026-10-23 Signals Week 4")
        #expect(plan.state.titleIsPlaceholder == false)
        #expect(plan.state.slides == [slide])
        // Recordings in another lecture folder are referenced in place, not copied.
        #expect(plan.state.audio == [lecture.audioURL])
        let contents = try FileManager.default.contentsOfDirectory(atPath: plan.folder.url.path)
        #expect(!contents.contains { $0.hasPrefix("audio") })
    }

    @Test func plannerTitleFromSlideDocumentTitle() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let memo = root.appendingPathComponent("memo.m4a")
        try Data("memo".utf8).write(to: memo)
        let slide = root.appendingPathComponent("slides-v2.pdf")
        try makePDF(at: slide, title: "Digital Product Engineering")

        let plan = try ReprocessPlanner.plan(request([memo], course: course, slides: [slide]), now: Self.now)

        #expect(plan.folder.url.lastPathComponent == "2026-10-23 Digital Product Engineering")
        #expect(plan.state.titleIsPlaceholder == false)
    }

    @Test func plannerRejectsEmptyRecordings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ReprocessPlannerError.noRecordings) {
            try ReprocessPlanner.plan(request([], course: root), now: Self.now)
        }
    }
}
