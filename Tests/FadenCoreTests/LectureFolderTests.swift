import Foundation
import Testing
@testable import FadenCore

@Suite struct LectureFolderTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func sanitiseReplacesColonAndSlash() {
        #expect(LectureFolder.sanitise("ISO:SAE 21434 / Teil 1") == "ISO-SAE 21434 - Teil 1")
    }

    @Test func titleFromSlide() {
        let url = URL(fileURLWithPath: "/x/261023-THI_Wi-Fi_Lecture_Part4.pdf")
        #expect(LectureFolder.title(fromSlide: url) == "261023-THI Wi-Fi Lecture Part4")
    }

    @Test func createAddsSuffixWhenTaken() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_761_200_000)
        let first = try LectureFolder.create(in: root, date: date, title: "Intro")
        let second = try LectureFolder.create(in: root, date: date, title: "Intro")
        #expect(first.url.lastPathComponent.hasSuffix(" Intro"))
        #expect(second.url.lastPathComponent == first.url.lastPathComponent + " (2)")
    }

    @Test func newNotesURLNeverReturnsExisting() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LectureFolder.create(in: root, date: Date(), title: "Notes")
        #expect(folder.newNotesURL(now: Date()) == folder.notesURL)
        try "x".write(to: folder.notesURL, atomically: true, encoding: .utf8)
        let next = folder.newNotesURL(now: Date())
        #expect(next.lastPathComponent.hasPrefix("notes (re-run "))
        try "y".write(to: next, atomically: true, encoding: .utf8)
        let third = folder.newNotesURL(now: Date())
        #expect(third != next)
        #expect(!FileManager.default.fileExists(atPath: third.path))
    }

    @Test func renameKeepsDatePrefix() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let folder = try LectureFolder.create(in: root, date: date, title: "Old")
        let renamed = try folder.rename(toTitle: "New: Title", date: date)
        #expect(renamed.url.lastPathComponent.hasSuffix(" New- Title"))
        #expect(FileManager.default.fileExists(atPath: renamed.url.path))
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func lectureFolderInAwkwardPath() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let course = root
            .appendingPathComponent("Masterstudium", isDirectory: true)
            .appendingPathComponent("Entwicklung eines TARA-Tools nach ISO:SAE 21434", isDirectory: true)
            .appendingPathComponent("OneDrive-Persönlich-Test", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        let folder = try LectureFolder.create(in: course, date: Date(), title: "Lecture 1")
        try "# Hallo".write(to: folder.notesURL, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: folder.notesURL, encoding: .utf8) == "# Hallo")
        #expect(!LectureFolder.isLectureFolder(folder.url))
        try FileManager.default.createDirectory(
            at: folder.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: folder.stateURL, atomically: true, encoding: .utf8)
        #expect(LectureFolder.isLectureFolder(folder.url))
    }
}
