import Foundation
import Testing
@testable import FadenCore

@Suite struct RecordingListTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func lectureFolder(in root: URL, named name: String, files: [String]) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try touch(dir.appendingPathComponent(".faden/state.json"))
        for file in files { try touch(dir.appendingPathComponent(file)) }
        return dir
    }

    @Test func keepsAudioFilesInPickOrderAndFiltersExtensionsCaseInsensitively() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let b = root.appendingPathComponent("b.AIFF")
        let a = root.appendingPathComponent("a.mp3")
        let pdf = root.appendingPathComponent("slides.pdf")
        for url in [a, b, pdf] { try touch(url) }
        let result = RecordingList.expand([b, pdf, a])
        #expect(result.recordings == [b, a])
        #expect(result.rejected == [RecordingList.Rejection(url: pdf, reason: .unsupportedType)])
    }

    @Test func lectureFolderContributesAllAudioFilesInNaturalOrder() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try lectureFolder(in: root, named: "261023 Intro", files: [
            "audio-10.m4a", "audio-2.m4a", "audio.m4a", "audio-3.aiff", "audio-extra.m4a", "notes.md", "transcript.md"])
        let result = RecordingList.expand([dir])
        #expect(result.recordings.map(\.lastPathComponent) == [
            "audio.m4a", "audio-2.m4a", "audio-3.aiff", "audio-10.m4a"])
        #expect(result.rejected.isEmpty)
    }

    @Test func directoryThatIsNotALectureFolderIsRejected() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("Course", isDirectory: true)
        try touch(plain.appendingPathComponent("audio.m4a"))
        let result = RecordingList.expand([plain])
        #expect(result.recordings.isEmpty)
        #expect(result.rejected == [RecordingList.Rejection(url: plain, reason: .notLectureFolder)])
    }

    @Test func lectureFolderWithoutAudioIsRejected() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try lectureFolder(in: root, named: "Empty", files: ["notes.md"])
        let result = RecordingList.expand([dir])
        #expect(result.rejected == [RecordingList.Rejection(url: dir, reason: .noAudio)])
    }

    @Test func addingSkipsFilesAlreadyInTheList() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.wav")
        let b = root.appendingPathComponent("b.wav")
        for url in [a, b] { try touch(url) }
        let result = RecordingList.adding([a, b, b], to: [a])
        #expect(result.recordings == [a, b])
    }

    @Test func moveUpAndDown() {
        let list = ["a", "b", "c"]
        #expect(RecordingList.movedUp(list, at: 1) == ["b", "a", "c"])
        #expect(RecordingList.movedDown(list, at: 1) == ["a", "c", "b"])
    }

    @Test func moveAtTheEdgesAndOutOfRangeChangesNothing() {
        let list = ["a", "b", "c"]
        #expect(RecordingList.movedUp(list, at: 0) == list)
        #expect(RecordingList.movedDown(list, at: 2) == list)
        #expect(RecordingList.movedUp(list, at: 7) == list)
        #expect(RecordingList.movedDown(list, at: -1) == list)
    }

    @Test func missingListsTheEntriesWhoseFileIsGone() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("a.m4a")
        let deleted = root.appendingPathComponent("b.m4a")
        try touch(kept)

        #expect(RecordingList.missing([kept, deleted]) == [deleted])
        #expect(RecordingList.missing([kept]).isEmpty)
    }
}
