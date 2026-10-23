import Foundation
import PDFKit

public enum SlideInputError: Error, Equatable {
    case unreadablePDF(String)
}

/// Turns slide PDFs into request content blocks.
public enum SlideInput {
    /// The default limit on the decks' combined raw file size. PDFs are sent base64-encoded, which is
    /// about 4/3 of the raw size, and the whole request must stay under the Messages API's 32 MB cap:
    /// 22 MB raw is about 29.3 MB encoded, leaving room for the transcript, notes and prompt.
    public static let defaultMaxTotalBytes = 22_000_000

    /// The default limit on the decks' combined page count (the API's PDF page limit per request).
    public static let defaultMaxTotalPages = 600

    /// Each PDF becomes a `document` block titled with its file name. While the decks sent as PDF
    /// together exceed `maxTotalBytes` (raw file bytes), the largest by size is sent as extracted text
    /// instead; then, while they exceed `maxTotalPages`, the one with the most pages is. Text-only decks
    /// count their text's bytes and no pages.
    /// With `cacheLast`, the last block is marked for caching, so re-runs of the notes call reuse the prefix.
    public static func blocks(for pdfs: [URL],
                              maxTotalBytes: Int = defaultMaxTotalBytes,
                              maxTotalPages: Int = defaultMaxTotalPages,
                              cacheLast: Bool = true) throws -> [ContentBlock] {
        let datas = try pdfs.map { try Data(contentsOf: $0) }
        let pageCounts = try zip(pdfs, datas).map { url, data in
            guard let document = PDFDocument(data: data) else {
                throw SlideInputError.unreadablePDF(url.lastPathComponent)
            }
            return document.pageCount
        }
        var blocks = zip(pdfs, datas).map { url, data in
            ContentBlock.pdf(base64: data.base64EncodedString(), title: url.lastPathComponent, cache: false)
        }

        var asPDF = Set(pdfs.indices)
        var totalBytes = datas.reduce(0) { $0 + $1.count }
        var totalPages = pageCounts.reduce(0, +)
        while true {
            let next: Int?
            if totalBytes > maxTotalBytes {
                next = asPDF.max { datas[$0].count < datas[$1].count }
            } else if totalPages > maxTotalPages {
                next = asPDF.max { pageCounts[$0] < pageCounts[$1] }
            } else {
                next = nil
            }
            guard let i = next else { break }
            let text = "Slides \(pdfs[i].lastPathComponent) (text only):\n" + (try pageText(pdfs[i]))
            blocks[i] = .text(text, cache: false)
            asPDF.remove(i)
            totalBytes += text.utf8.count - datas[i].count
            totalPages -= pageCounts[i]
        }

        if cacheLast, let last = blocks.indices.last {
            blocks[last] = blocks[last].cached()
        }
        return blocks
    }

    /// Marks pages without a text layer (e.g. scanned or image-only), so the model doesn't invent content.
    static let noTextMarker = "(no extractable text)"

    static func pageText(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw SlideInputError.unreadablePDF(url.lastPathComponent)
        }
        return (0..<document.pageCount).map { i in
            let text = (document.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "--- Slide \(i + 1) ---\n" + (text.isEmpty ? noTextMarker : text)
        }.joined(separator: "\n\n")
    }
}

private extension ContentBlock {
    func cached() -> ContentBlock {
        switch self {
        case .text(let text, _): .text(text, cache: true)
        case .pdf(let base64, let title, _): .pdf(base64: base64, title: title, cache: true)
        }
    }
}
