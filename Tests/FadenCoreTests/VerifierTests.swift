import CoreGraphics
import Foundation
import Testing
@testable import FadenCore

@Suite struct VerifierTests {
    private let transcript = Transcript(
        segments: [TranscriptSegment(start: 0, end: 5, text: "Heute geht es um den Handshake.")],
        markers: [], language: "de", model: "whisper-test")

    private let flag = " ⚠️ not found in sources"

    private func body(_ request: MessageRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Request

    @Test func verifyRequestShape() throws {
        let request = try Verifier.request(notes: "# Titel\n📄 Folie 1 Text", transcript: transcript, slides: [])
        let json = try body(request)

        #expect(json["model"] as? String == "claude-haiku-5-5")
        #expect(json["max_tokens"] as? Int == 16000)
        #expect(json["stream"] as? Bool == false)
        #expect(json["fallbacks"] == nil)
        #expect(request.betaHeaders.isEmpty)

        let format = try #require((json["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["unsupported"])
        #expect(schema["additionalProperties"] as? Bool == false)
        let unsupported = try #require((schema["properties"] as? [String: Any])?["unsupported"] as? [String: Any])
        #expect(unsupported["type"] as? String == "array")
        let item = try #require(unsupported["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["quote", "reason"])
        #expect(item["additionalProperties"] as? Bool == false)
        let props = try #require(item["properties"] as? [String: [String: String]])
        #expect(props == ["quote": ["type": "string"], "reason": ["type": "string"]])
    }

    @Test func requestSendsSlidesThenTranscriptThenNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("faden-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("deck.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let ctx = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()

        let request = try Verifier.request(notes: "NOTES BODY", transcript: transcript, slides: [pdf])
        let json = try body(request)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["document", "text", "text"])
        #expect(content[0]["title"] as? String == "deck.pdf")
        #expect(content[0]["cache_control"] != nil)
        #expect(content[1]["text"] as? String == transcript.markdown())
        #expect((content[2]["text"] as? String)?.hasSuffix("NOTES BODY") == true)

        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect(system.first?["text"] as? String == (try Verifier.systemPrompt()))
    }

    @Test func systemPromptNamesEveryLabelForm() throws {
        let prompt = try Verifier.systemPrompt()
        #expect(!prompt.contains("Placeholder"))
        for form in ["📄 Folie 12", "📄 Slide 12–14", "📄 <file>.pdf, Folie 12", "🗣 [HH:MM:SS]", "💡", "✍️",
                     "unsupported", "quote"] {
            #expect(prompt.contains(form), "missing \(form)")
        }
    }

    // MARK: - Parse

    @Test func parseDecodesFindings() throws {
        let findings = try Verifier.parse(#"{"unsupported":[{"quote":"a","reason":"b"}]}"#)
        #expect(findings == [Finding(quote: "a", reason: "b")])
        #expect(try Verifier.parse(#"{"unsupported":[]}"#).isEmpty)
    }

    @Test func parseThrowsOnMalformedInput() {
        #expect(throws: (any Error).self) { try Verifier.parse("not json") }
        #expect(throws: (any Error).self) { try Verifier.parse("{}") }
        #expect(throws: (any Error).self) { try Verifier.parse(#"{"other":[]}"#) }
        #expect(throws: (any Error).self) { try Verifier.parse(#"{"unsupported":[{"quote":"a"}]}"#) }
    }

    // MARK: - Merge

    @Test func mergeFlagsLineOnce() {
        let notes = "# T\n📄 Folie 3 TCP has four layers\n🗣 [00:00:05] other"
        let result = Verifier.merge([Finding(quote: "four layers", reason: "x"),
                                     Finding(quote: "TCP has", reason: "y")], into: notes)
        #expect(result.notes == "# T\n📄 Folie 3 TCP has four layers" + flag + "\n🗣 [00:00:05] other")
        #expect(result.unmatched == 0)
    }

    @Test func mergeNeverDoubleFlagsAnAlreadyFlaggedLine() {
        let notes = "📄 Folie 3 claim" + flag
        let result = Verifier.merge([Finding(quote: "claim", reason: "x")], into: notes)
        #expect(result.notes == notes)
        #expect(result.unmatched == 0)
    }

    @Test func mergeKeepsEverything() {
        let notes = "a\n\n📄 b\r\n🗣 c\n"
        let result = Verifier.merge([Finding(quote: "b", reason: "x")], into: notes)
        #expect(result.notes.components(separatedBy: "\n").count == notes.components(separatedBy: "\n").count)
        #expect(result.notes == "a\n\n📄 b" + flag + "\r\n🗣 c\n")
    }

    @Test func mergeFlagsDifferentLinesSeparately() {
        let result = Verifier.merge([Finding(quote: "one", reason: "x"), Finding(quote: "two", reason: "y")],
                                    into: "one\ntwo")
        #expect(result.notes == "one" + flag + "\ntwo" + flag)
    }

    @Test func unmatchedCounted() {
        let result = Verifier.merge([Finding(quote: "absent", reason: "x"), Finding(quote: "", reason: "y")],
                                    into: "present")
        #expect(result.notes == "present")
        #expect(result.unmatched == 2)
    }

    @Test func mergeUsesExactMatching() {
        let result = Verifier.merge([Finding(quote: "Handshake", reason: "x")], into: "handshake")
        #expect(result.unmatched == 1)
        #expect(result.notes == "handshake")
    }
}
