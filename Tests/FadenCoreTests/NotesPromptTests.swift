import CoreGraphics
import CoreText
import Foundation
import ImageIO
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

    /// Writes a 400×300 pt PDF with one page per string, each drawn as real (extractable) text; an empty
    /// string gives a page with only a filled rectangle. Pages in `figures` also get a 600×240 px image
    /// drawn at 300×120 pt (2 px per pt), pages in `diagrams` three stroked boxes, and with `logo` every
    /// page gets the same small image in the corner. Figures differ by page and `variant`, unless
    /// `repeatFigure` draws the same one on every page.
    private func makePDF(_ pages: [String], named name: String, in dir: URL, figures: Set<Int> = [],
                         diagrams: Set<Int> = [], logo: Bool = false, variant: Int = 0,
                         repeatFigure: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for (i, text) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            if figures.contains(i) { ctx.draw(try image(width: 600, height: 240, seed: variant * 100 + (repeatFigure ? 0 : i)), in: CGRect(x: 50, y: 20, width: 300, height: 120)) }
            if diagrams.contains(i) {
                for x in [40, 160, 280] { ctx.stroke(CGRect(x: x, y: 30, width: 60, height: 40)) }
            }
            if logo { ctx.draw(try image(width: 30, height: 30, seed: 999), in: CGRect(x: 360, y: 260, width: 30, height: 30)) }
            guard !text.isEmpty else {
                // An image-only page: a drawn shape, no text layer.
                ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
                ctx.fill(CGRect(x: 50, y: 50, width: 300, height: 200))
                ctx.endPDFPage()
                continue
            }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 20, y: 150)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A raster image with some noise, so its JPEG isn't trivially small; `seed` varies the pattern.
    private func image(width: Int, height: Int, seed: Int) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in stride(from: 0, to: width, by: 10) {
            for y in stride(from: 0, to: height, by: 10) {
                ctx.setFillColor(CGColor(red: CGFloat((x * 7 + y * 3 + seed * 37) % 255) / 255, green: CGFloat(x % 255) / 255,
                                         blue: CGFloat(y % 255) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 10, height: 10))
            }
        }
        return try #require(ctx.makeImage())
    }

    /// The pixel size of a base64 image block's image.
    private func pixelSize(_ base64: String) throws -> CGSize {
        let data = try #require(Data(base64Encoded: base64))
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        return CGSize(width: image.width, height: image.height)
    }

    /// Short descriptions of slide blocks: the first line of a text block, "image" for an image.
    private func kinds(_ blocks: [ContentBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case .text(let text, _): text.components(separatedBy: "\n").first ?? ""
            case .image: "image"
            }
        }
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
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        #expect(json["tool_choice"] == nil)
        let raw = try #require(String(data: try JSONEncoder().encode(request), encoding: .utf8))
        #expect(!raw.contains("budget_tokens"))
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect(request.betaHeaders == ["server-side-fallback-2026-07-01"])

        let content = try userContent(request)
        #expect(content.map { $0["type"] as? String } == ["text", "text", "text", "text"])
        #expect(content.map { $0["cache_control"] != nil } == [false, true, false, false])
        #expect((content[1]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        #expect(content[0]["text"] as? String
            == "Slides Deck One.pdf (text only):\n--- Slide 1 ---\nIntro\n\n--- Slide 2 ---\nHandshake")
        #expect(content[1]["text"] as? String == "Slides Deck Two.pdf (text only):\n--- Slide 1 ---\nSummary")

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

    @Test func baseSystemPromptHasLabelRules() throws {
        let base = try NotesPrompt.baseSystemPrompt()
        for label in ["`📄`", "`🗣`", "`💡`", "`✍️`"] {
            #expect(base.contains(label), "missing label \(label)")
        }
        #expect(base.contains("The first line is `# <lecture title>`"))
        #expect(base.contains("`📄 Folie 12`"))
        #expect(base.contains("`🗣 [00:23:14]`"))
    }

    @Test func additionsOffAddsRule() throws {
        let system = try systemText(try NotesPrompt.request(inputs(allowAdditions: false)))
        #expect(system.hasSuffix("STYLE BODY\n\n" + NotesPrompt.noAdditionsRule))
        #expect(NotesPrompt.noAdditionsRule.hasPrefix(
            "Do not add explanations, examples or context of your own; omit 💡 entirely. "
            + "This overrides any instruction above that asks for 💡 content, such as likely exam questions "
            + "or your own examples; leave those out"))
    }

    @Test func additionsOffRuleComesAfterStylesThatAskForAdditions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StyleStore(dir: dir)
        try store.installDefaultsIfMissing()

        for id in ["A-slide-by-slide", "C-red-line"] {
            let style = try store.resolve(id: id, hasSlides: true)
            #expect(style.prompt.contains("💡"), "\(id) no longer asks for 💡 content")
            let request = try NotesPrompt.request(NotesInputs(
                transcript: transcript, slides: [], userNotes: nil, style: style,
                allowAdditions: false, languageOverride: "de"))
            let system = try systemText(request)
            let styleEnd = try #require(system.range(of: style.prompt)).upperBound
            let rule = try #require(system.range(of: NotesPrompt.noAdditionsRule))
            #expect(rule.lowerBound > styleEnd)
            #expect(system.hasSuffix(NotesPrompt.noAdditionsRule + "\n\nWrite the notes in German."))
        }
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

    @Test func figurePagesAreFollowedByTheirCroppedImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try makePDF(["Intro", "Diagram", "Outro", ""], named: "deck.pdf", in: dir, figures: [1])

        let blocks = try SlideInput.blocks(for: [deck])

        #expect(blocks.count == 3)
        guard case .text(let first, let firstCache) = blocks[0],
              case .image(let base64, let mediaType, let imageCache) = blocks[1],
              case .text(let rest, let restCache) = blocks[2] else {
            Issue.record("expected text, image, text, got \(blocks)")
            return
        }
        #expect(first == "Slides deck.pdf (text per page; a page with figures is followed by an image of them):\n"
            + "--- Slide 1 ---\nIntro\n\n--- Slide 2 ---\nDiagram")
        #expect(mediaType == "image/jpeg")
        // The figure's 300×120 pt plus 6 pt padding on each side, at the image's own 2 px per pt.
        #expect(try pixelSize(base64) == CGSize(width: 624, height: 264))
        #expect(rest == "--- Slide 3 ---\nOutro\n\n--- Slide 4 ---\n(no extractable text)")
        #expect([firstCache, imageCache, restCache] == [false, false, true])
    }

    @Test func vectorDiagramIsAFigureButALoneShapeIsNot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Page 2 is only a filled rectangle (one path); page 1 has three boxes.
        let deck = try makePDF(["Flow", ""], named: "flow.pdf", in: dir, diagrams: [0])

        let blocks = try SlideInput.blocks(for: [deck])

        #expect(kinds(blocks) == ["Slides flow.pdf (text per page; a page with figures is followed by an image of them):",
                                  "image", "--- Slide 2 ---"])
        guard case .image(let base64, _, _) = blocks[1] else { return }
        // The boxes span 40…340 × 30…70 pt, padded by 6 pt on each side, at 1.5 px per pt.
        #expect(try pixelSize(base64) == CGSize(width: 312 * 1.5, height: 52 * 1.5))
    }

    @Test func templateImagesAreNotFigures() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try makePDF(["A", "B", "C", "D"], named: "logo.pdf", in: dir, figures: [2], logo: true)

        let blocks = try SlideInput.blocks(for: [deck])

        #expect(kinds(blocks).filter { $0 == "image" }.count == 1)
        guard case .image(let base64, _, _) = blocks[1] else {
            Issue.record("expected the figure of slide 3, got \(blocks)")
            return
        }
        // Cropped to the figure alone; the logo in the corner would widen it.
        #expect(try pixelSize(base64) == CGSize(width: 624, height: 264))
    }

    @Test func differentImagesAtTheSamePlaceOnEveryPageAreAllFigures() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Like a scanned deck: an image in the same place on every page, but a different one each time.
        let deck = try makePDF(["P1", "P2", "P3", "P4", "P5"], named: "scan.pdf", in: dir, figures: Set(0..<5))

        #expect(kinds(try SlideInput.blocks(for: [deck])).filter { $0 == "image" }.count == 5)
    }

    @Test func oversizedFiguresDegradeDecksToText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = try makePDF(["Only page"], named: "small.pdf", in: dir, figures: [0], variant: 1)
        let large = try makePDF(["Handshake basics", "Four way exchange"], named: "large.pdf", in: dir, figures: [0, 1])
        let full = try SlideInput.blocks(for: [large, small], maxTotalBytes: .max)
        let figureBytes = full.reduce(0) { sum, block in
            if case .image(let base64, _, _) = block { sum + (Data(base64Encoded: base64)?.count ?? 0) } else { sum }
        }

        let blocks = try SlideInput.blocks(for: [large, small], maxTotalBytes: figureBytes)

        #expect(kinds(blocks) == ["Slides large.pdf (text only):",
                                  "Slides small.pdf (text per page; a page with figures is followed by an image of them):",
                                  "image"])
        guard case .text(let text, _) = blocks[0] else { return }
        #expect(text == "Slides large.pdf (text only):\n--- Slide 1 ---\nHandshake basics\n\n--- Slide 2 ---\nFour way exchange")
    }

    @Test func tooManyImagesDegradeDecksWithMostFigures() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = try makePDF(["O1"], named: "one.pdf", in: dir, figures: [0], variant: 1)
        let three = try makePDF(["T1", "T2", "T3"], named: "three.pdf", in: dir, figures: [0, 1, 2])
        let two = try makePDF(["W1", "W2"], named: "two.pdf", in: dir, figures: [0, 1], variant: 2)

        func images(_ blocks: [ContentBlock]) -> Int { kinds(blocks).filter { $0 == "image" }.count }

        // 6 images, limit 2: the 3-figure deck goes to text, then the 2-figure deck (6 → 3 → 1).
        let blocks = try SlideInput.blocks(for: [one, three, two], maxTotalImages: 2)
        #expect(images(blocks) == 1)
        #expect(kinds(blocks).filter { $0.hasSuffix("(text only):") } == ["Slides three.pdf (text only):", "Slides two.pdf (text only):"])

        // Exactly at the limit: nothing degrades.
        #expect(images(try SlideInput.blocks(for: [one, three, two], maxTotalImages: 6)) == 6)
    }

    @Test func imageOnlyPageIsMarkedAsHavingNoText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try makePDF(["Handshake basics", ""], named: "scan.pdf", in: dir)

        let blocks = try SlideInput.blocks(for: [deck])
        guard case .text(let text, _) = try #require(blocks.first) else {
            Issue.record("expected the deck as text, got \(blocks)")
            return
        }
        #expect(blocks.count == 1)
        #expect(text == "Slides scan.pdf (text only):\n--- Slide 1 ---\nHandshake basics\n\n--- Slide 2 ---\n(no extractable text)")
    }

    @Test func defaultLimitsLeaveRoomUnderTheRequestCap() {
        #expect(SlideInput.defaultMaxTotalBytes == 22_000_000)
        #expect(SlideInput.defaultMaxTotalBytes * 4 / 3 < 32_000_000)
        #expect(SlideInput.defaultMaxTotalImages == 600)
    }

    @Test func repeatedFigureIsReferredToInsteadOfSentAgain() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try makePDF(["A", "B", "C"], named: "deck.pdf", in: dir, figures: [0, 2], repeatFigure: true)
        let other = try makePDF(["X"], named: "other.pdf", in: dir, figures: [0])

        let blocks = try SlideInput.blocks(for: [deck])
        #expect(kinds(blocks) == ["Slides deck.pdf (text per page; a page with figures is followed by an image of them):",
                                  "image", "--- Slide 2 ---"])
        guard case .text(let rest, _) = blocks[2] else { return }
        #expect(rest == "--- Slide 2 ---\nB\n\n--- Slide 3 ---\nC\n"
            + "(This page shows exactly the same figure as Slide 1; see the image after Slide 1 above.)")

        // Across decks the reference names the deck; `other` has the same figure on its first page.
        let both = try SlideInput.blocks(for: [deck, other])
        #expect(kinds(both).filter { $0 == "image" }.count == 1)
        guard case .text(let last, _) = try #require(both.last) else { return }
        #expect(last == "Slides other.pdf (text per page; a page with figures is followed by an image of them):\n"
            + "--- Slide 1 ---\nX\n(This page shows exactly the same figure as Slide 1 of deck.pdf; "
            + "see the image after Slide 1 of deck.pdf above.)")
    }

    @Test func pdfNotesAreSentLikeSlidesAfterThem() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try makePDF(["Intro"], named: "deck.pdf", in: dir)
        // No extension, like an exported notes file; it's recognised by its content.
        let notes = try makePDF(["Typed line", ""], named: "notes-26-10-26", in: dir, figures: [1], variant: 5)
        #expect(SlideInput.isPDF(notes))
        #expect(!SlideInput.isPDF(deck.deletingLastPathComponent().appendingPathComponent("missing")))

        let content = try userContent(try NotesPrompt.request(inputs(slides: [deck], userNotes: notes)))

        #expect(content.map { $0["type"] as? String } == ["text", "text", "image", "text"])
        #expect(content[0]["text"] as? String == "Slides deck.pdf (text only):\n--- Slide 1 ---\nIntro")
        #expect(content[1]["text"] as? String
            == "My own notes from the lecture (label content from here ✍️), notes-26-10-26 "
            + "(text per page; a page with figures is followed by an image of them):\n"
            + "--- Page 1 ---\nTyped line\n\n--- Page 2 ---")
        #expect(content.map { $0["cache_control"] != nil } == [false, false, true, false])
        #expect(content[3]["text"] as? String == transcript.markdown())
    }

    @Test func textNotesAreNotTakenForPDFs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appendingPathComponent("notes.pdf")
        try "PDF- looks like one but isn't".write(to: notes, atomically: true, encoding: .utf8)
        #expect(!SlideInput.isPDF(notes))
        let content = try userContent(try NotesPrompt.request(inputs(userNotes: notes)))
        #expect(content.first?["text"] as? String
            == "My own notes from the lecture (label content from here ✍️):\nPDF- looks like one but isn't")
    }

    @Test func checkSendsFiguresOnlyForCitedSlidesAndTheirNeighbours() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try makePDF(["S1", "S2", "S3", "S4", "S5"], named: "deck.pdf", in: dir, figures: [0, 1, 3, 4])

        let request = try Verifier.request(notes: "- Claim 📄 Folie 1", transcript: transcript, slides: [deck])
        let content = try userContent(request)

        // Slides 1 and 2 (cited and its neighbour) get images; 4 and 5 only say they have a figure.
        #expect(content.map { $0["type"] as? String } == ["text", "image", "text", "image", "text", "text", "text"])
        #expect(content[4]["text"] as? String == "--- Slide 3 ---\nS3\n\n"
            + "--- Slide 4 ---\nS4\n(its figure isn't included here)\n\n"
            + "--- Slide 5 ---\nS5\n(its figure isn't included here)")
        #expect(content.allSatisfy { $0["cache_control"] == nil })
    }

    @Test func noDecksGiveNoBlocks() throws {
        #expect(try SlideInput.blocks(for: []).isEmpty)
    }
}
