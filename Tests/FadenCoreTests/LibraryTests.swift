import Foundation
import Testing
@testable import FadenCore

@Suite struct LibraryTests {
    private let fm = FileManager.default

    private func makeTempRoot() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("faden-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A lecture folder `name` in `course` with `.faden/`, and a `state.json` when `stage` is given.
    @discardableResult
    private func lecture(_ name: String, in course: URL, stage: Stage? = nil, failedStage: Stage? = nil,
                         error: String? = nil, slides: [URL] = [], placeholder: Bool = false,
                         files: [String: String] = [:]) throws -> URL {
        let url = course.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url.appendingPathComponent(".faden"), withIntermediateDirectories: true)
        if let stage {
            var state = PipelineState(stage: stage, audio: [url.appendingPathComponent("audio.m4a")], slides: slides,
                                      styleID: "C-red-line", allowAdditions: true, titleIsPlaceholder: placeholder)
            state.failedStage = failedStage
            state.error = error
            try JSONEncoder().encode(state).write(to: LectureFolder(url: url).stateURL)
        }
        for (file, text) in files {
            try text.write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test func listsOnlyFadenFoldersNewestFirst() throws {
        let course = try makeTempRoot()
        defer { try? fm.removeItem(at: course) }
        try lecture("2026-10-14 Introduction", in: course, stage: .done, files: ["notes.md": "# Intro"])
        try lecture("2026-10-23 Consensus and Raft", in: course, stage: .ready)
        try lecture("2026-10-21 Clocks", in: course, stage: .transcribing)
        try fm.createDirectory(at: course.appendingPathComponent("Exercises"), withIntermediateDirectories: true)
        try "x".write(to: course.appendingPathComponent("syllabus.pdf"), atomically: true, encoding: .utf8)

        let lectures = Library.lectures(in: course)
        #expect(lectures.map(\.title) == ["Consensus and Raft", "Clocks", "Introduction"])
        #expect(lectures.allSatisfy { $0.course == course })
    }

    @Test func treeFindsLecturesInSubfoldersAndSkipsEmptyBranches() throws {
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }
        let course = root.appendingPathComponent("Digital Process Engineering")
        let topic = course.appendingPathComponent("Pflegeprozesse")
        try lecture("2026-10-20 Einführung", in: course, stage: .done, files: ["notes.md": "x"])
        try lecture("2026-10-22 Pflegeplanung", in: topic, stage: .ready)
        try lecture("2026-10-27 Dokumentation", in: topic.appendingPathComponent("Übungen"), stage: .done,
                     files: ["notes.md": "x"])
        try fm.createDirectory(at: course.appendingPathComponent("Literatur/Papers"), withIntermediateDirectories: true)
        // A lecture folder isn't searched further.
        let raft = try lecture("2026-10-23 Raft", in: root, stage: .done, files: ["notes.md": "x"])
        try lecture("2026-10-24 Nested", in: raft, stage: .ready)

        let tree = Library.tree(at: root)
        #expect(tree.lectures.map(\.title) == ["Raft"])
        #expect(tree.children.map(\.name) == ["Digital Process Engineering"])
        let dpe = tree.children[0]
        #expect(dpe.lectures.map(\.title) == ["Einführung"])
        #expect(dpe.children.map(\.name) == ["Pflegeprozesse"])
        #expect(dpe.children[0].children.map(\.name) == ["Übungen"])
        #expect(dpe.allLectures.map(\.title) == ["Dokumentation", "Pflegeplanung", "Einführung"])
        #expect(dpe.allLectures.first?.course.lastPathComponent == "Übungen")

        let found = try #require(tree.folder(LibraryFolder(url: topic, lectures: [], children: []).id))
        #expect(found.name == "Pflegeprozesse")
        #expect(tree.path(to: topic) == [root.lastPathComponent, "Digital Process Engineering", "Pflegeprozesse"])
        #expect(tree.path(to: fm.temporaryDirectory).isEmpty)
    }

    @Test func treeStopsAtMaxDepth() throws {
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }
        try lecture("2026-10-01 Deep", in: root.appendingPathComponent("a/b/c"), stage: .ready)
        #expect(Library.tree(at: root, maxDepth: 3).allLectures.count == 1)
        #expect(Library.tree(at: root, maxDepth: 2).allLectures.isEmpty)
    }

    @Test func statusFromState() throws {
        let course = try makeTempRoot()
        defer { try? fm.removeItem(at: course) }
        try lecture("2026-10-01 A", in: course, stage: .ready)
        try lecture("2026-10-02 B", in: course, stage: .writingNotes)
        try lecture("2026-10-03 C", in: course, stage: .failed, failedStage: .verifying, error: "HTTP 529 overloaded")
        try lecture("2026-10-04 D", in: course, stage: .done, files: ["notes.md": "# D"])
        try lecture("2026-10-05 E", in: course, stage: .done)
        try lecture("2026-10-06 F", in: course, files: ["notes.md": "# F"])
        try lecture("2026-10-07 G", in: course)

        let status = Dictionary(uniqueKeysWithValues: Library.lectures(in: course).map { ($0.title, $0.status) })
        #expect(status["A"] == .ready)
        #expect(status["B"] == .interrupted(.writingNotes))
        #expect(status["C"] == .failed(stage: .verifying, error: "HTTP 529 overloaded"))
        #expect(status["D"] == .done)
        #expect(status["E"] == .notesMissing)
        #expect(status["F"] == .done)  // no state, but notes
        #expect(status["G"] == .unknown)
    }

    @Test func notesNewestFirst() throws {
        let course = try makeTempRoot()
        defer { try? fm.removeItem(at: course) }
        let url = try lecture("2026-10-23 Raft", in: course, stage: .done, files: [
            "notes.md": "a",
            "notes (re-run 2026-10-24 18-02).md": "b",
            "notes (re-run 2026-10-24 18-02) (2).md": "c",
            "notes (re-run 2026-10-30 09-15).md": "d",
            "transcript.md": "t",
        ])
        let found = try #require(Library.lecture(at: url, course: course))
        #expect(found.notes.map(\.lastPathComponent) == [
            "notes (re-run 2026-10-30 09-15).md",
            "notes (re-run 2026-10-24 18-02) (2).md",
            "notes (re-run 2026-10-24 18-02).md",
            "notes.md",
        ])
        #expect(found.transcript?.lastPathComponent == "transcript.md")
    }

    @Test func slidesTranscriptLengthAndCost() throws {
        let course = try makeTempRoot()
        defer { try? fm.removeItem(at: course) }
        let slide = course.appendingPathComponent("DS-07 Consensus.pdf")
        let notes = "# Raft\n\n> Generated by Faden on 2026-10-23\n> Cost: $0.82 (1200 in / 300 out tokens)\n\nBody"
        let url = try lecture("2026-10-23 Raft", in: course, stage: .done, slides: [slide], files: ["notes.md": notes])
        let transcript = Transcript(
            segments: [.init(start: 0, end: 40, text: "a"), .init(start: 40, end: 5460, text: "b")],
            markers: [], language: "en", model: "m")
        try JSONEncoder().encode(transcript).write(to: LectureFolder(url: url).transcriptMetaURL)

        let found = try #require(Library.lecture(at: url, course: course))
        #expect(found.slides == [slide])
        #expect(found.length == 5460)
        #expect(found.cost == "$0.82")
        #expect(found.transcript == nil)
        #expect(!found.inCloud)
    }

    @Test func placeholderTitleAndUndatedFolder() throws {
        let course = try makeTempRoot()
        defer { try? fm.removeItem(at: course) }
        try lecture("2026-10-24 Lecture", in: course, stage: .ready, placeholder: true)
        try lecture("Old lecture", in: course, files: ["notes.md": "x"])
        let lectures = Library.lectures(in: course)
        #expect(lectures.map(\.title) == ["Lecture", "Old lecture"])
        #expect(lectures[0].titleIsPlaceholder)
        #expect(lectures[1].date == nil)
    }

    @Test func iCloudPlaceholdersAreListedUnderTheirRealNamesAndNotRead() throws {
        let course = try makeTempRoot()
        defer { try? fm.removeItem(at: course) }
        let url = try lecture("2026-10-14 Introduction", in: course, files: [".notes.md.icloud": "", "transcript.md": "t"])
        try "".write(to: url.appendingPathComponent(".faden/.state.json.icloud"), atomically: true, encoding: .utf8)

        let found = try #require(Library.lecture(at: url, course: course))
        #expect(found.notes == [url.appendingPathComponent("notes.md")])
        #expect(found.status == .done)
        #expect(found.inCloud)
        #expect(found.cost == nil)
    }

    @Test func stateStillInCloudWithoutNotes() throws {
        let course = try makeTempRoot()
        defer { try? fm.removeItem(at: course) }
        let url = try lecture("2026-10-14 Introduction", in: course)
        try "".write(to: url.appendingPathComponent(".faden/.state.json.icloud"), atomically: true, encoding: .utf8)
        let found = try #require(Library.lecture(at: url, course: course))
        #expect(found.status == .unknown)
        #expect(found.inCloud)
    }

    @Test func parsesFolderNames() {
        let (date, title) = Library.parse(folderName: "2026-10-23 Consensus and Raft (2)")
        #expect(title == "Consensus and Raft (2)")
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: try! #require(date))
        #expect([parts.year, parts.month, parts.day] == [2026, 10, 23])
        #expect(Library.parse(folderName: "2026-10-23").title == "Lecture")
        #expect(Library.parse(folderName: "2026-13-45 Nope").date == nil)
        #expect(Library.parse(folderName: "Exercises").title == "Exercises")
    }

    @Test func rerunDates() throws {
        let date = try #require(Library.rerunDate(ofNotes: "notes (re-run 2026-10-24 18-02) (2).md"))
        let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: date)
        #expect([parts.day, parts.hour, parts.minute] == [24, 18, 2])
        #expect(Library.rerunDate(ofNotes: "notes.md") == nil)
    }

    @Test func costLine() {
        #expect(Library.cost(inNotesText: "# T\n\n> Cost: $1.20 (1 in / 2 out tokens)\n") == "$1.20")
        #expect(Library.cost(inNotesText: "> Cost: Claude subscription, limit use: 3% session (5 in / 6 out tokens)")
                == "Subscription")
        #expect(Library.cost(inNotesText: "> Cost: — (price unknown for x) (1 in / 2 out tokens)") == nil)
        #expect(Library.cost(inNotesText: "# T\n\nNo header") == nil)
    }
}

@Suite struct CourseListTests {
    private let fm = FileManager.default

    private func makeFolder(_ name: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("faden-test-\(UUID().uuidString)/\(name)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addsOnceAndRemoves() throws {
        let a = try makeFolder("Distributed Systems")
        let b = try makeFolder("Analysis II")
        defer { [a, b].forEach { try? fm.removeItem(at: $0.deletingLastPathComponent()) } }
        var list = CourseList()
        let first = try list.add(a)
        try list.add(b)
        #expect(try list.add(a) == first)
        #expect(list.courses.map(\.name) == ["Distributed Systems", "Analysis II"])
        list.remove(first.id)
        #expect(list.courses.map(\.name) == ["Analysis II"])
    }

    @Test func aSubfolderOfAListedFolderIsNotAddedAgain() throws {
        let parent = try makeFolder("Digital Process Engineering")
        defer { try? fm.removeItem(at: parent.deletingLastPathComponent()) }
        let child = parent.appendingPathComponent("Pflegeprozesse", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        var list = CourseList()
        let course = try list.add(parent)
        #expect(try list.add(child) == course)
        #expect(list.courses.count == 1)
    }

    @Test func aParentReplacesListedSubfolders() throws {
        let parent = try makeFolder("Digital Process Engineering")
        defer { try? fm.removeItem(at: parent.deletingLastPathComponent()) }
        let child = parent.appendingPathComponent("Pflegeprozesse", isDirectory: true)
        let sibling = parent.deletingLastPathComponent().appendingPathComponent("Digital Process Engineering 2")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        var list = CourseList()
        try list.add(child)
        try list.add(sibling)  // shares the name prefix, but isn't inside
        try list.add(parent)
        #expect(list.courses.map(\.name) == ["Digital Process Engineering 2", "Digital Process Engineering"])
    }

    @Test func followsARenamedFolder() throws {
        let a = try makeFolder("Old name")
        defer { try? fm.removeItem(at: a.deletingLastPathComponent()) }
        var list = CourseList()
        let course = try list.add(a)
        let renamed = a.deletingLastPathComponent().appendingPathComponent("New name", isDirectory: true)
        try fm.moveItem(at: a, to: renamed)

        let resolved = list.resolve(course.id)
        let url = try #require(resolved)
        #expect(url.standardizedFileURL.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
        #expect(list.courses[0].name == "New name")
    }

    @Test func roundTripsThroughJSON() throws {
        let a = try makeFolder("Course")
        defer { try? fm.removeItem(at: a.deletingLastPathComponent()) }
        var list = CourseList()
        try list.add(a)
        let decoded = try JSONDecoder().decode(CourseList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }
}
