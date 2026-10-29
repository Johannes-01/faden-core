import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FadenCore

@Suite struct SlideImagesTests {
    private static func decks(_ files: [(String, Int)]) -> [SlideImages.Deck] {
        SlideImages.decks(files.map { (name: $0.0, pages: $0.1) })
    }

    private static let one = decks([("Wi-Fi_Part1.pdf", 3)])

    @Test func placeholdersBecomeImageLinks() {
        let notes = """
        # Wi-Fi

        ![Folie 1](slide:1)

        ## Scanning

        ![Folie 2](slide:2)
        ![Folie 3](slide:3)

        - 🗣 Passive scanning saves power.
        """
        #expect(SlideImages.place(in: notes, decks: Self.one) == """
        # Wi-Fi

        ![Folie 1](slide-images/Wi-Fi_Part1-001.png)

        ## Scanning

        ![Folie 2](slide-images/Wi-Fi_Part1-002.png)
        ![Folie 3](slide-images/Wi-Fi_Part1-003.png)

        - 🗣 Passive scanning saves power.
        """)
    }

    @Test func aLeftOutSlideIsInsertedAboveTheNextSlidesHeading() {
        let notes = """
        # Wi-Fi

        ![Folie 1](slide:1)

        ## Roaming

        ![Folie 3](slide:3)
        """
        #expect(SlideImages.place(in: notes, decks: Self.one) == """
        # Wi-Fi

        ![Folie 1](slide-images/Wi-Fi_Part1-001.png)

        ![Folie 2](slide-images/Wi-Fi_Part1-002.png)

        ## Roaming

        ![Folie 3](slide-images/Wi-Fi_Part1-003.png)
        """)
    }

    @Test func slidesLeftOutAtTheEndGoBeforeTheNextSection() {
        let notes = """
        # Wi-Fi

        ## Intro

        ![Slide 1](slide:1)

        - 🗣 Said.

        ## Unclear in recording

        - nothing
        """
        #expect(SlideImages.place(in: notes, decks: Self.one) == """
        # Wi-Fi

        ## Intro

        ![Slide 1](slide-images/Wi-Fi_Part1-001.png)

        - 🗣 Said.

        ![Slide 2](slide-images/Wi-Fi_Part1-002.png)

        ![Slide 3](slide-images/Wi-Fi_Part1-003.png)

        ## Unclear in recording

        - nothing
        """)
    }

    @Test func unknownAndRepeatedPlaceholdersAreDropped() {
        let notes = "# T\n\n![Folie 1](slide:1)\n![Folie 1](slide:1)\n![Folie 9](slide:9)\n![Folie 2](slide:Other.pdf/2)\n![Folie 2](slide:2) ⚠️ not found in sources\n![Folie 3](slide:3)"
        #expect(SlideImages.place(in: notes, decks: Self.one) == """
        # T

        ![Folie 1](slide-images/Wi-Fi_Part1-001.png)
        ![Folie 2](slide-images/Wi-Fi_Part1-002.png) ⚠️ not found in sources
        ![Folie 3](slide-images/Wi-Fi_Part1-003.png)
        """)
    }

    @Test func severalDecksAreNamedAndKeepTheirOwnFiles() {
        let decks = Self.decks([("Part 1 (intro).pdf", 1), ("part 1 (intro).PDF", 2)])
        #expect(decks.map(\.stem) == ["Part-1--intro-", "part-1--intro--2"])
        let notes = """
        # T

        ![Folie 1](slide:Part 1 (intro).pdf/1)

        ## Next

        ![Folie 2](slide:part 1 (intro).PDF/2)
        """
        #expect(SlideImages.place(in: notes, decks: decks) == """
        # T

        ![Folie 1](slide-images/Part-1--intro--001.png)

        ![part 1 (intro).PDF, Folie 1](slide-images/part-1--intro--2-001.png)

        ## Next

        ![Folie 2](slide-images/part-1--intro--2-002.png)
        """)
    }

    @Test func notesWithoutPlaceholdersGetEverySlideAtTheEnd() {
        #expect(SlideImages.place(in: "# T\n\n- 🗣 Said.", decks: Self.decks([("D.pdf", 2)]))
            == "# T\n\n- 🗣 Said.\n\n![Slide 1](slide-images/D-001.png)\n\n![Slide 2](slide-images/D-002.png)")
    }

    // MARK: Rendering

    static func makePDF(at url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 225)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for i in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: CGFloat(i) / CGFloat(max(pages, 1)), alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
    }

    @Test func embedRendersEachPageAsPNGOnceAndReusesIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "faden-slide-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appending(path: "Deck.pdf")
        try Self.makePDF(at: pdf, pages: 2)
        let folder = root.appending(path: "Lecture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let notes = try SlideImages.embed(in: "# T\n\n![Folie 1](slide:1)", slides: [pdf], folder: folder)
        #expect(notes == "# T\n\n![Folie 1](slide-images/Deck-001.png)\n\n![Folie 2](slide-images/Deck-002.png)")
        let image = folder.appending(path: "slide-images/Deck-002.png")
        let png = try Data(contentsOf: image)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let size = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 800)

        // Processing again keeps an image that is newer than its PDF.
        try Data("kept".utf8).write(to: image)
        _ = try SlideImages.embed(in: "# T", slides: [pdf], folder: folder)
        #expect(try Data(contentsOf: image) == Data("kept".utf8))

        // A changed PDF renders it again.
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: image.path)
        _ = try SlideImages.embed(in: "# T", slides: [pdf], folder: folder)
        #expect(try Data(contentsOf: image).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func unreadablePDFFails() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "faden-slide-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bad = root.appending(path: "Bad.pdf")
        try Data("not a pdf".utf8).write(to: bad)
        #expect(throws: SlideInputError.unreadablePDF("Bad.pdf")) {
            try SlideImages.embed(in: "# T", slides: [bad], folder: root)
        }
    }
}
