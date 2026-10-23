import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FadenCore

@Suite struct NotesPromptTests {
    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a PDF with one page per string, each drawn as real (extractable) text.
    private func makePDF(_ pages: [String], named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for text in pages {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 20, y: 150)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func size(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    private let transcript = Transcript(
        segments: [
            TranscriptSegment(start: 0, end: 5, text: "Heute geht es um den Handscheg."),
            TranscriptSegment(start: 65, end: 70, text: "Das ist prüfungsrelevant."),
        ],
        markers: [], language: "de", model: "whisper-test")

    private let style = NoteStyle(id: "C-red-line", name: "C", requiresSlides: false,
                                  fallbackID: nil, prompt: "STYLE BODY")

    private func inputs(slides: [URL] = [], userNotes: URL? = nil, allowAdditions: Bool = true,
                        languageOverride: String? = nil) -> NotesInputs {
        NotesInputs(transcript: transcript, slides: slides, userNotes: userNotes, style: style,
                    allowAdditions: allowAdditions, languageOverride: languageOverride)
    }

    private func body(_ request: MessageRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func systemText(_ request: MessageRequest) throws -> String {
        let system = try #require(try body(request)["system"] as? [[String: Any]])
        #expect(system.count == 1)
        return try #require(system.first?["text"] as? String)
    }

    private func userContent(_ request: MessageRequest) throws -> [[String: Any]] {
        let messages = try #require(try body(request)["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        return try #require(messages.first?["content"] as? [[String: Any]])
    }

    // MARK: - Request

    @Test func requestShape() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck1 = try makePDF(["Intro", "Handshake"], named: "Deck One.pdf", in: dir)
        let deck2 = try makePDF(["Summary"], named: "Deck Two.pdf", in: dir)
        let notes = dir.appendingPathComponent("DPE - Session 1")
        try "handshake = 4 steps?".write(to: notes, atomically: true, encoding: .utf8)

        let request = try NotesPrompt.request(inputs(slides: [deck1, deck2], userNotes: notes))
        let json = try body(request)

        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["max_tokens"] as? Int == 64000)
        #expect(json["stream"] as? Bool == true)
        #expect(json["fallbacks"] as? String == "default")
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "high")
        #expect(json["thinking"] == nil)
        #expect(json["temperature"] == nil)
        #expect(request.betaHeaders == ["server-side-fallback-2026-07-01"])

        let content = try userContent(request)
        #expect(content.map { $0["type"] as? String } == ["document", "document", "text", "text"])
        #expect(content.map { $0["title"] as? String } == ["Deck One.pdf", "Deck Two.pdf", nil, nil])
        #expect(content.map { $0["cache_control"] != nil } == [false, true, false, false])
        #expect((content[1]["cache_control"] as? [String: String]) == ["type": "ephemeral"])

        let source = try #require(content[0]["source"] as? [String: String])
        #expect(source["type"] == "base64")
        #expect(source["media_type"] == "application/pdf")
        #expect(source["data"] == (try Data(contentsOf: deck1)).base64EncodedString())

        #expect(content[2]["text"] as? String
            == "My own notes from the lecture (label content from here ✍️):\nhandshake = 4 steps?")
        #expect(content[3]["text"] as? String == transcript.markdown())
    }

    @Test func systemIsNotesPromptPlusStyle() throws {
        let request = try NotesPrompt.request(inputs())
        let system = try systemText(request)
        let base = try NotesPrompt.baseSystemPrompt()
        #expect(!base.contains("Placeholder"))
        #expect(system == base + "\n\n## Style\nSTYLE BODY")
        #expect(system.contains("🗣"))
        #expect(system.contains("Unclear in recording"))
        #expect(!system.contains("omit 💡 entirely"))
        #expect(!system.contains("Write the notes in German."))
        #expect(!system.contains("Write the notes in English."))
    }

    @Test func withoutSlidesOrNotesOnlyTranscriptIsSent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty notes")
        try " \n\n".write(to: empty, atomically: true, encoding: .utf8)

        let content = try userContent(try NotesPrompt.request(inputs(userNotes: empty)))
        #expect(content.count == 1)
        #expect(content.first?["text"] as? String == transcript.markdown())
    }

    @Test func userNotesFallBackToLatin1() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appendingPathComponent("Notizen")
        try #require("Prüfung: Übertragung".data(using: .isoLatin1)).write(to: notes)

        let content = try userContent(try NotesPrompt.request(inputs(userNotes: notes)))
        #expect((content.first?["text"] as? String)?.hasSuffix("\nPrüfung: Übertragung") == true)
    }

    @Test func additionsOffAddsRule() throws {
        let system = try systemText(try NotesPrompt.request(inputs(allowAdditions: false)))
        #expect(system.hasSuffix("Do not add explanations, examples or context of your own; omit 💡 entirely."))
    }

    @Test(arguments: [
        ("de", "Write the notes in German."),
        ("en", "Write the notes in English."),
        ("fr", "Write the notes in the language with code fr."),
    ])
    func languageOverrideIsAppended(code: String, sentence: String) throws {
        let system = try systemText(try NotesPrompt.request(inputs(allowAdditions: false, languageOverride: code)))
        #expect(system.hasSuffix(sentence))
        #expect(system.contains("omit 💡 entirely."))
    }

    // MARK: - Slide input

    @Test func oversizedDecksDegradeToText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = try makePDF(["Only page"], named: "small.pdf", in: dir)
        let large = try makePDF(["Handshake basics", "Four way exchange"], named: "large.pdf", in: dir)
        let total = try size(small) + size(large)
        #expect(try size(large) > size(small))

        let blocks = try SlideInput.blocks(for: [large, small], maxTotalBytes: total - 1)

        #expect(blocks.count == 2)
        guard case .text(let text, let textCache) = blocks[0] else {
            Issue.record("expected the larger deck as text, got \(blocks[0])")
            return
        }
        #expect(text.hasPrefix("Slides large.pdf (text only):\n"))
        #expect(text.contains("--- Slide 1 ---\nHandshake basics"))
        #expect(text.contains("--- Slide 2 ---\nFour way exchange"))
        #expect(!textCache)
        guard case .pdf(_, let title, let pdfCache) = blocks[1] else {
            Issue.record("expected the smaller deck as PDF, got \(blocks[1])")
            return
        }
        #expect(title == "small.pdf")
        #expect(pdfCache)
    }

    @Test func decksWithinLimitStayPDFs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makePDF(["A"], named: "a.pdf", in: dir)
        let b = try makePDF(["B"], named: "b.pdf", in: dir)

        let blocks = try SlideInput.blocks(for: [a, b], maxTotalBytes: try size(a) + size(b))

        let titles = blocks.compactMap { block -> String? in
            if case .pdf(_, let title, _) = block { title } else { nil }
        }
        #expect(titles == ["a.pdf", "b.pdf"])
        #expect(try SlideInput.blocks(for: []).isEmpty)
    }
}
