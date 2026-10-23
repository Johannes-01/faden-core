import Foundation
import PDFKit

public enum SlideInputError: Error, Equatable {
    case unreadablePDF(String)
}

/// Turns slide PDFs into request content blocks.
public enum SlideInput {
    /// Each PDF becomes a `document` block titled with its file name. If the decks together exceed
    /// `maxTotalBytes`, the largest are sent as extracted text instead until the total fits.
    /// The last block is marked for caching, so re-runs and the verify call can reuse the prefix.
    public static func blocks(for pdfs: [URL], maxTotalBytes: Int = 30_000_000) throws -> [ContentBlock] {
        let datas = try pdfs.map { try Data(contentsOf: $0) }
        var blocks = zip(pdfs, datas).map { url, data in
            ContentBlock.pdf(base64: data.base64EncodedString(), title: url.lastPathComponent, cache: false)
        }

        var total = datas.reduce(0) { $0 + $1.count }
        let largestFirst = datas.indices.sorted { datas[$0].count > datas[$1].count }
        for i in largestFirst where total > maxTotalBytes {
            let text = "Slides \(pdfs[i].lastPathComponent) (text only):\n" + (try pageText(pdfs[i]))
            blocks[i] = .text(text, cache: false)
            total += text.utf8.count - datas[i].count
        }

        if let last = blocks.indices.last {
            blocks[last] = blocks[last].cached()
        }
        return blocks
    }

    static func pageText(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw SlideInputError.unreadablePDF(url.lastPathComponent)
        }
        return (0..<document.pageCount).map { i in
            "--- Slide \(i + 1) ---\n" + (document.page(at: i)?.string ?? "")
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
