import Foundation
import PDFKit

public enum SlideInputError: Error, Equatable {
    case unreadablePDF(String)
}

/// Turns slide PDFs (and the student's notes, when they are a PDF) into request content blocks.
public enum SlideInput {
    /// The default limit on the slides' combined raw size (page text plus figure JPEGs). Images are sent
    /// base64-encoded, which is about 4/3 of the raw size, and the whole request must stay under the
    /// Messages API's 32 MB cap: 22 MB raw is about 29.3 MB encoded, leaving room for the transcript,
    /// notes and prompt.
    public static let defaultMaxTotalBytes = 22_000_000

    /// The default limit on the number of figure images (the API's image limit per request).
    public static let defaultMaxTotalImages = 600

    /// Each deck is sent as its pages' text, one `--- Slide N ---` section per page, under a header with
    /// the deck's file name. A page with a figure (an image, diagram or table) is followed by one image
    /// block showing its figures cropped from the page; text-only pages cost no image. This is far cheaper
    /// than a PDF document, which the API turns into a full page image plus text for every page. A figure
    /// identical to an earlier one (a repeated slide) is referred to instead of sent again.
    ///
    /// The student's own notes, when they are a PDF, follow the slides in the same form, with
    /// `--- Page N ---` sections under the ✍️ notes header, and share the slides' limits.
    ///
    /// `includeFigure(file name, page)` picks the pages whose figures are sent (pages counted from 1); the
    /// others say that their figure isn't included. Then, while the PDFs exceed `maxTotalBytes`, the one
    /// whose figures are largest is sent as text only; then, while they exceed `maxTotalImages`, the one
    /// with the most figures is.
    /// With `cacheLast`, the last block is marked for caching, so re-runs of the notes call reuse the prefix.
    public static func blocks(for pdfs: [URL],
                              notes: URL? = nil,
                              maxTotalBytes: Int = defaultMaxTotalBytes,
                              maxTotalImages: Int = defaultMaxTotalImages,
                              includeFigure: (String, Int) -> Bool = { _, _ in true },
                              cacheLast: Bool = true) throws -> [ContentBlock] {
        var decks = try pdfs.map { try Deck(url: $0, kind: .slides) }
        if let notes { decks.append(try Deck(url: notes, kind: .notes)) }
        for d in decks.indices {
            for (i, figure) in decks[d].figures.enumerated() where figure != nil && !includeFigure(decks[d].name, i + 1) {
                decks[d].figures[i] = nil
                decks[d].omitted.insert(i)
            }
        }

        var totalBytes = decks.reduce(0) { $0 + $1.textBytes + $1.figureBytes }
        var totalImages = decks.reduce(0) { $0 + $1.figureCount }
        while true {
            let withFigures = decks.indices.filter { decks[$0].figureCount > 0 }
            let next: Int?
            if totalBytes > maxTotalBytes {
                next = withFigures.max { decks[$0].figureBytes < decks[$1].figureBytes }
            } else if totalImages > maxTotalImages {
                next = withFigures.max { decks[$0].figureCount < decks[$1].figureCount }
            } else {
                next = nil
            }
            guard let i = next else { break }
            totalBytes -= decks[i].figureBytes
            totalImages -= decks[i].figureCount
            decks[i].figures = decks[i].figures.map { _ in nil }
        }

        var sent: [Data: String] = [:]
        var blocks = decks.flatMap { $0.blocks(sent: &sent, namesDeck: pdfs.count > 1) }
        if cacheLast, let last = blocks.indices.last {
            blocks[last] = blocks[last].cached()
        }
        return blocks
    }

    /// Whether the file is a PDF, by its content rather than its name.
    public static func isPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 5)) == Data("%PDF-".utf8)
    }

    /// Marks pages without a text layer (e.g. scanned or image-only), so the model doesn't invent content.
    static let noTextMarker = "(no extractable text)"

    static func pageTexts(_ url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else {
            throw SlideInputError.unreadablePDF(url.lastPathComponent)
        }
        return (0..<document.pageCount).map { i in
            (document.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private struct Deck {
    enum Kind { case slides, notes }

    var name: String
    var kind: Kind
    var texts: [String]
    /// One JPEG per page, nil for pages without a figure or whose figure is left out.
    var figures: [Data?]
    /// Pages (from 0) whose figure was left out on purpose; they say so.
    var omitted: Set<Int> = []

    init(url: URL, kind: Kind) throws {
        name = url.lastPathComponent
        self.kind = kind
        texts = try SlideInput.pageTexts(url)
        figures = try SlideFigures.figures(url)
    }

    var textBytes: Int { texts.reduce(0) { $0 + $1.utf8.count } }
    var figureBytes: Int { figures.reduce(0) { $0 + ($1?.count ?? 0) } }
    var figureCount: Int { figures.count { $0 != nil } }

    private var pageWord: String { kind == .slides ? "Slide" : "Page" }

    /// What a later page calls this deck's page `n` when it shows the same figure.
    private func reference(_ n: Int, namesDeck: Bool) -> String {
        switch kind {
        case .slides: namesDeck ? "Slide \(n) of \(name)" : "Slide \(n)"
        case .notes: "Page \(n) of my notes"
        }
    }

    /// Text sections, each run closed by the image of the page it ends with. `sent` maps the figures
    /// sent so far to their reference, so a repeated figure is referred to instead of sent again.
    func blocks(sent: inout [Data: String], namesDeck: Bool) -> [ContentBlock] {
        let format = figureCount == 0 ? "text only" : "text per page; a page with figures is followed by an image of them"
        let header = switch kind {
        case .slides: "Slides \(name) (\(format)):\n"
        case .notes: "My own notes from the lecture (label content from here ✍️), \(name) (\(format)):\n"
        }
        var blocks: [ContentBlock] = []
        var sections: [String] = []
        for (i, text) in texts.enumerated() {
            let figure = i < figures.count ? figures[i] : nil
            let earlier = figure.flatMap { sent[$0] }
            var body = text.isEmpty ? (figure == nil ? "\n" + SlideInput.noTextMarker : "") : "\n" + text
            if let earlier { body += "\n(This page shows exactly the same figure as \(earlier); see the image after \(earlier) above.)" }
            if omitted.contains(i) { body += "\n(its figure isn't included here)" }
            sections.append("--- \(pageWord) \(i + 1) ---" + body)
            if let figure, earlier == nil {
                sent[figure] = reference(i + 1, namesDeck: namesDeck)
                blocks.append(.text((blocks.isEmpty ? header : "") + sections.joined(separator: "\n\n"), cache: false))
                blocks.append(.image(base64: figure.base64EncodedString(), mediaType: "image/jpeg", cache: false))
                sections = []
            }
        }
        if !sections.isEmpty || blocks.isEmpty {
            blocks.append(.text((blocks.isEmpty ? header : "") + sections.joined(separator: "\n\n"), cache: false))
        }
        return blocks
    }
}

private extension ContentBlock {
    func cached() -> ContentBlock {
        switch self {
        case .text(let text, _): .text(text, cache: true)
        case .image(let base64, let mediaType, _): .image(base64: base64, mediaType: mediaType, cache: true)
        }
    }
}
