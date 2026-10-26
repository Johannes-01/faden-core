import Foundation
import PDFKit

public enum SlideInputError: Error, Equatable {
    case unreadablePDF(String)
}

/// Turns slide PDFs into request content blocks.
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
    /// than a PDF document, which the API turns into a full page image plus text for every page.
    ///
    /// While the slides exceed `maxTotalBytes`, the deck whose figures are largest is sent as text only;
    /// then, while they exceed `maxTotalImages`, the one with the most figures is.
    /// With `cacheLast`, the last block is marked for caching, so re-runs of the notes call reuse the prefix.
    public static func blocks(for pdfs: [URL],
                              maxTotalBytes: Int = defaultMaxTotalBytes,
                              maxTotalImages: Int = defaultMaxTotalImages,
                              cacheLast: Bool = true) throws -> [ContentBlock] {
        var decks = try pdfs.map { url in
            Deck(name: url.lastPathComponent, texts: try pageTexts(url), figures: try SlideFigures.figures(url))
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

        var blocks = decks.flatMap(\.blocks)
        if cacheLast, let last = blocks.indices.last {
            blocks[last] = blocks[last].cached()
        }
        return blocks
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
    var name: String
    var texts: [String]
    /// One JPEG per page, nil for pages without a figure.
    var figures: [Data?]

    var textBytes: Int { texts.reduce(0) { $0 + $1.utf8.count } }
    var figureBytes: Int { figures.reduce(0) { $0 + ($1?.count ?? 0) } }
    var figureCount: Int { figures.count { $0 != nil } }

    /// Text sections, each run closed by the image of the page it ends with.
    var blocks: [ContentBlock] {
        let header = figureCount == 0
            ? "Slides \(name) (text only):\n"
            : "Slides \(name) (text per page; a page with figures is followed by an image of them):\n"
        var blocks: [ContentBlock] = []
        var sections: [String] = []
        for (i, text) in texts.enumerated() {
            let figure = i < figures.count ? figures[i] : nil
            let body = text.isEmpty ? (figure == nil ? "\n" + SlideInput.noTextMarker : "") : "\n" + text
            sections.append("--- Slide \(i + 1) ---" + body)
            if let figure {
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
