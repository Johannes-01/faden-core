import CoreGraphics
import Foundation
import os
import UniformTypeIdentifiers

public enum SlideImagesError: Error, Equatable {
    /// A page could not be rendered; carries the deck's file name and the page, from 1.
    case unrenderablePage(String, Int)
}

/// Puts the slides into notes written by a style with `slide_images`. The model marks where each slide goes
/// with a placeholder, `![Folie 12](slide:12)`, or `![Folie 12](slide:Deck.pdf/12)` with several decks.
/// Saving replaces each with a link to a PNG of that page in the lecture folder's `slide-images/`, so the
/// model never writes a file path and the images cost no tokens. Every page appears exactly once: a
/// placeholder for an unknown slide or a slide placed before is dropped, and a slide the model left out is
/// inserted where it belongs in the deck's order.
public enum SlideImages {
    public static let directoryName = "slide-images"
    /// 144 dpi: sharp on a Retina screen, about 50–250 KB per slide. Slides are mostly flat colour, so PNG
    /// comes out smaller than JPEG. `SlideFigures.maxEdge` still caps the longest side.
    static let scale: CGFloat = 2

    private static let log = Logger(subsystem: FadenCore.identifier, category: "SlideImages")

    /// `![alt](slide:12)` or `![alt](slide:<deck file name>/12)`, anywhere in a line, so a ⚠️ flag the check
    /// appended doesn't hide it.
    nonisolated(unsafe) private static let placeholder = /!\[([^\]\n]*)\]\(slide:(?:([^\n]+?)\/)?(\d+)\)/

    struct Deck: Equatable {
        /// The PDF's file name, as the notes request names the deck.
        var name: String
        var pages: Int
        /// The image file names' prefix: the name without `.pdf`, with characters that break a Markdown link
        /// replaced, and unique among the decks.
        var stem: String
    }

    /// A slide by its deck's index and its page, from 1; ordered as the decks are.
    struct Slide: Hashable, Comparable {
        var deck: Int
        var page: Int

        static func < (a: Slide, b: Slide) -> Bool { (a.deck, a.page) < (b.deck, b.page) }
    }

    /// The notes with their placeholders replaced by images of the slides, which are rendered into
    /// `folder/slide-images/`. An image newer than its PDF is kept, so processing again doesn't render it twice.
    public static func embed(in notes: String, slides: [URL], folder: URL) throws -> String {
        let documents = try slides.map { url in
            guard let document = CGPDFDocument(url as CFURL) else { throw SlideInputError.unreadablePDF(url.lastPathComponent) }
            return document
        }
        let decks = Self.decks(zip(slides, documents).map { ($0.lastPathComponent, $1.numberOfPages) })

        let fm = FileManager.default
        let dir = folder.appending(path: directoryName, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var rendered = 0
        for (i, deck) in decks.enumerated() where deck.pages > 0 {
            let changed = try? slides[i].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            for page in 1...deck.pages {
                let target = folder.appending(path: link(deck, page))
                if let made = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   let changed, made >= changed { continue }
                guard let pdfPage = documents[i].page(at: page),
                      let png = SlideFigures.render(pdfPage, area: pdfPage.getBoxRect(.cropBox), scale: scale, type: .png)
                else { throw SlideImagesError.unrenderablePage(deck.name, page) }
                try png.write(to: target, options: .atomic)
                rendered += 1
            }
        }
        log.info("Rendered \(rendered) slide images, kept \(decks.reduce(0) { $0 + $1.pages } - rendered)")
        return place(in: notes, decks: decks)
    }

    static func decks(_ files: [(name: String, pages: Int)]) -> [Deck] {
        var used = Set<String>()
        return files.map { file in
            var base = (file.name as NSString).deletingPathExtension
            base = String(base.map { $0.isWhitespace || "()[]<>#%?&".contains($0) ? "-" : $0 })
            if base.isEmpty { base = "slides" }
            var stem = base
            var n = 2
            while !used.insert(stem.lowercased()).inserted {
                stem = "\(base)-\(n)"
                n += 1
            }
            return Deck(name: file.name, pages: file.pages, stem: stem)
        }
    }

    /// The image's path relative to the lecture folder, e.g. `slide-images/Wi-Fi_Part1-012.png`.
    static func link(_ deck: Deck, _ page: Int) -> String {
        "\(directoryName)/\(deck.stem)-\(String(format: "%03d", page)).png"
    }

    /// Replaces the placeholders with image links and inserts the slides the model left out: before the
    /// section of the next slide that is there (above its heading), or, after the last one, before the next
    /// `#`/`##` heading or at the end.
    static func place(in notes: String, decks: [Deck]) -> String {
        var lines: [String?] = notes.components(separatedBy: "\n")
        var placed: [Slide: Int] = [:]
        var lastDeck = 0
        var word: String?
        var dropped = 0

        for i in lines.indices {
            guard let line = lines[i], line.contains("](slide:") else { continue }
            let replaced = line.replacing(placeholder) { match -> String in
                guard let deck = resolve(match.2.map(String.init), in: decks, default: lastDeck),
                      let page = Int(match.3), page >= 1, page <= decks[deck].pages,
                      placed[Slide(deck: deck, page: page)] == nil
                else {
                    dropped += 1
                    return ""
                }
                lastDeck = deck
                placed[Slide(deck: deck, page: page)] = i
                let alt = String(match.1)
                if word == nil, let first = alt.split(separator: " ").first, Int(first) == nil { word = String(first) }
                return "![\(alt)](\(link(decks[deck], page)))"
            }
            let blank = replaced.trimmingCharacters(in: .whitespaces).isEmpty
            lines[i] = blank ? nil : replaced
        }

        let all = decks.indices.flatMap { d in (0..<decks[d].pages).map { Slide(deck: d, page: $0 + 1) } }
        let missing = all.filter { placed[$0] == nil }
        if dropped > 0 || !missing.isEmpty {
            log.notice("Slide placeholders: \(placed.count) placed, \(dropped) dropped, \(missing.count) inserted")
        }

        func isHeading(_ line: String?) -> Bool { line?.hasPrefix("#") == true }
        func sectionStart(_ i: Int) -> Int {
            var j = i - 1
            while j >= 0, lines[j]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { j -= 1 }
            return j >= 0 && isHeading(lines[j]) ? j : i
        }
        func afterLastSection() -> Int {
            guard let last = placed.values.max() else { return lines.count }
            return lines.indices.first { $0 > last && (lines[$0]?.hasPrefix("# ") == true || lines[$0]?.hasPrefix("## ") == true) }
                ?? lines.count
        }

        var insertions: [Int: [String]] = [:]
        for slide in missing {
            let next = placed.filter { $0.key > slide }.min { $0.key < $1.key }?.value
            let at = next.map(sectionStart) ?? afterLastSection()
            let alt = [word ?? "Slide", "\(slide.page)"].joined(separator: " ")
            let altWithDeck = decks.count > 1 ? "\(decks[slide.deck].name), \(alt)" : alt
            insertions[at, default: []].append("![\(altWithDeck)](\(link(decks[slide.deck], slide.page)))")
        }
        for (at, images) in insertions.sorted(by: { $0.key > $1.key }) {
            let block = at == lines.count
                ? images.flatMap { ["", $0] }
                : images.flatMap { [$0, ""] }
            lines.insert(contentsOf: block.map(Optional.some), at: at)
        }
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    /// The deck a placeholder names: its file name, ignoring case and the `.pdf` extension. Without a name,
    /// the deck of the previous placeholder.
    private static func resolve(_ name: String?, in decks: [Deck], default current: Int) -> Int? {
        guard !decks.isEmpty else { return nil }
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return current }
        func bare(_ s: String) -> String { (s as NSString).deletingPathExtension.lowercased() }
        return decks.firstIndex { $0.name == name }
            ?? decks.firstIndex { $0.name.lowercased() == name.lowercased() }
            ?? decks.firstIndex { bare($0.name) == bare(name) }
    }
}
