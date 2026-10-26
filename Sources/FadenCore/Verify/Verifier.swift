import Foundation

public struct Finding: Codable, Equatable, Sendable {
    public var quote: String
    public var reason: String

    public init(quote: String, reason: String) {
        self.quote = quote
        self.reason = reason
    }
}

public enum VerifierError: Error, Equatable {
    case missingResource(String)
}

/// Builds the Haiku request that flags note lines the sources don't support, and applies its findings.
public enum Verifier {
    static let flag = " ⚠️ not found in sources"
    /// The model the check asks for.
    public static let model = "claude-haiku-5-5"

    public static func request(notes: String, transcript: Transcript, slides: [URL]) throws -> MessageRequest {
        // Slides first, then the transcript, then the notes under test. Nothing is cached: the cache is
        // per model, so the notes call's cached slides can't be read here, and a check runs once per lecture.
        // Every slide's text is sent, but figures only for the slides the notes cite and their neighbours.
        let cited = citedSlides(in: notes, decks: slides.map(\.lastPathComponent))
        var content = try SlideInput.blocks(for: slides, includeFigure: { cited[$0]?.contains($1) == true },
                                            cacheLast: false)
        content.append(.text(transcript.markdown(), cache: false))
        content.append(.text("Notes to check:\n\n" + notes, cache: false))

        return MessageRequest(
            model: model,
            maxTokens: 16000,
            stream: false,
            system: [.text(try systemPrompt(), cache: false)],
            messages: [Message(content: content)],
            outputConfig: OutputConfig(format: JSONSchemaFormat(schema: schema)))
    }

    /// A range wider than this (e.g. a summary citing `Folie 3–30`) adds only its two ends.
    static let maxCitedRange = 10

    /// The pages each deck's 📄 labels cite, plus the pages next to them, since the check accepts a
    /// slightly wrong slide number. A label naming a deck's file counts for that deck, one without a
    /// file name for every deck.
    static func citedSlides(in notes: String, decks: [String]) -> [String: Set<Int>] {
        var cited: [String: Set<Int>] = [:]
        let label = /📄([^\n|📄🗣💡✍⚠]*)/
        let number = /(\d+)(?:\s*[–—-]\s*(\d+))?/
        for match in notes.matches(of: label) {
            var text = String(match.1)
            let named = decks.filter { text.contains($0) }
            for name in named { text = text.replacingOccurrences(of: name, with: " ") }
            var pages = Set<Int>()
            for n in text.matches(of: number) {
                guard let first = Int(n.1) else { continue }
                let last = n.2.flatMap { Int($0) } ?? first
                let range = min(first, last)...max(first, last)
                pages.formUnion(range.count > maxCitedRange + 1 ? [range.lowerBound, range.upperBound] : Set(range))
            }
            let near = pages.flatMap { [$0 - 1, $0, $0 + 1] }
            for name in named.isEmpty ? decks : named { cited[name, default: []].formUnion(near) }
        }
        return cited
    }

    public static func parse(_ text: String) throws -> [Finding] {
        struct Response: Decodable { let unsupported: [Finding] }
        return try JSONDecoder().decode(Response.self, from: Data(text.utf8)).unsupported
    }

    /// Appends the flag to the first line containing each finding's quote, once per line. Nothing is deleted.
    public static func merge(_ findings: [Finding], into notes: String) -> (notes: String, unmatched: Int) {
        var lines = notes.components(separatedBy: "\n")
        var flagged = Set<Int>()
        var unmatched = 0
        for finding in findings {
            guard !finding.quote.isEmpty,
                  let i = lines.firstIndex(where: { $0.contains(finding.quote) }) else {
                unmatched += 1
                continue
            }
            let line = lines[i]
            let body = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard !flagged.contains(i), !body.hasSuffix(flag) else { continue }
            lines[i] = body + flag + (line.hasSuffix("\r") ? "\r" : "")
            flagged.insert(i)
        }
        return (lines.joined(separator: "\n"), unmatched)
    }

    static func systemPrompt() throws -> String {
        guard let url = FadenCore.resources.url(forResource: "verify-system", withExtension: "md", subdirectory: "prompts") else {
            throw VerifierError.missingResource("prompts/verify-system.md")
        }
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "unsupported": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "quote": .object(["type": .string("string")]),
                        "reason": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("quote"), .string("reason")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("unsupported")]),
        "additionalProperties": .bool(false),
    ])
}
