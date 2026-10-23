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

    public static func request(notes: String, transcript: Transcript, slides: [URL]) throws -> MessageRequest {
        // Slides first (the last block is cached), then the transcript, then the notes under test.
        var content = try SlideInput.blocks(for: slides)
        content.append(.text(transcript.markdown(), cache: false))
        content.append(.text("Notes to check:\n\n" + notes, cache: false))

        return MessageRequest(
            model: "claude-haiku-5-5",
            maxTokens: 16000,
            stream: false,
            system: [.text(try systemPrompt(), cache: false)],
            messages: [Message(content: content)],
            outputConfig: OutputConfig(format: JSONSchemaFormat(schema: schema)))
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
