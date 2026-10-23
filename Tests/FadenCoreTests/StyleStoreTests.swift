import Foundation
import Testing
@testable import FadenCore

@Suite struct StyleStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-styles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func installDefaultsDoesNotOverwrite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StyleStore(dir: dir)
        try store.installDefaultsIfMissing()
        let c = dir.appendingPathComponent("C-red-line.md")
        let edited = "---\nname: My C\n---\nMy own prompt.\n"
        try edited.write(to: c, atomically: true, encoding: .utf8)

        try store.installDefaultsIfMissing()

        #expect(try String(contentsOf: c, encoding: .utf8) == edited)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A-slide-by-slide.md").path))
    }

    @Test func installCreatesMissingDirectory() throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("styles", isDirectory: true)
        try StyleStore(dir: dir).installDefaultsIfMissing()
        #expect(try StyleStore(dir: dir).all().map(\.id) == ["A-slide-by-slide", "B-by-topic", "C-red-line"])
    }

    @Test func bundledDefaultsParse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StyleStore(dir: dir)
        try store.installDefaultsIfMissing()
        let styles = try store.all()
        let a = try #require(styles.first { $0.id == "A-slide-by-slide" })
        #expect(a.requiresSlides)
        #expect(a.fallbackID == "B-by-topic")
        for style in styles {
            #expect(!style.prompt.isEmpty)
            #expect(!style.prompt.hasPrefix("---"))
            #expect(style.name != style.id)
        }
        #expect(styles.filter(\.requiresSlides).map(\.id) == ["A-slide-by-slide"])
    }

    @Test func styleAFallsBackToBWithoutSlides() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StyleStore(dir: dir)
        try store.installDefaultsIfMissing()
        #expect(try store.resolve(id: "A-slide-by-slide", hasSlides: false).id == "B-by-topic")
        #expect(try store.resolve(id: "A-slide-by-slide", hasSlides: true).id == "A-slide-by-slide")
        #expect(try store.resolve(id: "C-red-line", hasSlides: false).id == "C-red-line")
    }

    @Test func userStyleAppears() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StyleStore(dir: dir)
        try store.installDefaultsIfMissing()
        try "---\nname: D · Flashcards\nrequires_slides: false\ncolour: blue\n---\nWrite flashcards.\n"
            .write(to: dir.appendingPathComponent("D-flashcards.md"), atomically: true, encoding: .utf8)

        let d = try #require(try store.all().first { $0.id == "D-flashcards" })
        #expect(d == NoteStyle(id: "D-flashcards", name: "D · Flashcards", requiresSlides: false,
                               fallbackID: nil, prompt: "Write flashcards."))
        #expect(try store.all().map(\.id).last == "D-flashcards")
    }

    @Test func missingNameFallsBackToID() throws {
        let style = try StyleStore.parse(id: "E-short", text: "---\nrequires_slides: true\n---\nBody\n")
        #expect(style.name == "E-short")
        #expect(style.requiresSlides)
        #expect(style.fallbackID == nil)
    }

    @Test func malformedFileIsSkippedByAll() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "no front matter here".write(to: dir.appendingPathComponent("X-bad.md"), atomically: true, encoding: .utf8)
        try "---\nname: Unclosed\nBody".write(to: dir.appendingPathComponent("Y-bad.md"), atomically: true, encoding: .utf8)
        try "---\nrequires_slides: maybe\n---\nBody".write(to: dir.appendingPathComponent("Z-bad.md"), atomically: true, encoding: .utf8)
        try "---\nname: Good\n---\nBody".write(to: dir.appendingPathComponent("G-good.md"), atomically: true, encoding: .utf8)
        try "not a style".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let store = StyleStore(dir: dir)
        #expect(try store.all().map(\.id) == ["G-good"])
        #expect(throws: StyleStoreError.malformed("X-bad")) { try store.resolve(id: "X-bad", hasSlides: true) }
    }

    @Test func leadingByteOrderMarkIsIgnored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("F-bom.md")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("---\r\nname: F · BOM\r\n---\r\nBody\r\n".utf8)).write(to: url)

        let style = try StyleStore(dir: dir).resolve(id: "F-bom", hasSlides: true)
        #expect(style == NoteStyle(id: "F-bom", name: "F · BOM", requiresSlides: false, fallbackID: nil, prompt: "Body"))
        #expect(try StyleStore.parse(id: "G", text: "\u{FEFF}---\nname: G\n---\nBody").name == "G")
    }

    @Test func resolveThrowsForUnknownID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: StyleStoreError.notFound("nope")) {
            try StyleStore(dir: dir).resolve(id: "nope", hasSlides: true)
        }
    }
}
