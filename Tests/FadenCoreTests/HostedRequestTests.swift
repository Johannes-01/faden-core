import Foundation
import Testing
@testable import FadenCore

@Suite struct HostedRequestTests {
    enum Fixtures {
        static let transcript = Transcript(
            segments: [TranscriptSegment(start: 0, end: 5, text: "Heute geht es um den Handshake.")],
            markers: [], language: "de", model: "whisper-test")

        static func notesRequest(stylePrompt: String, allowAdditions: Bool, language: String?) throws -> MessageRequest {
            let style = NoteStyle(id: "t", name: "T", requiresSlides: false, fallbackID: nil, prompt: stylePrompt)
            return try NotesPrompt.request(NotesInputs(
                transcript: transcript, slides: [], userNotes: nil, style: style,
                allowAdditions: allowAdditions, languageOverride: language))
        }

        static func request(for step: CostRecord.Step) throws -> MessageRequest {
            switch step {
            case .notes: try notesRequest(stylePrompt: "Style X", allowAdditions: false, language: "de")
            case .verify: try Verifier.request(notes: "# T\n📄 Folie 1 Text", transcript: transcript, slides: [])
            case .flashcards: try Flashcards.request(notes: "# T\n\nEin Satz.", examples: "Was ist TCP?")
            case .studyGuide: try StudyGuide.request([.init(title: "L", path: "Block/L", notes: "# T\n\nEin Satz.")])
            }
        }
    }

    private func jsonString(_ r: MessageRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(r), as: UTF8.self)
    }

    @Test(arguments: [CostRecord.Step.notes, .verify, .flashcards, .studyGuide])
    func rebuiltRequestMatchesOriginalExceptModel(step: CostRecord.Step) throws {
        let original = try Fixtures.request(for: step)
        #expect(original.tag?.step == step)
        let rebuilt = try HostedRequest.make(tag: original.tag!, messages: original.messages, model: "m-test")
        var expected = original
        expected.model = "m-test"
        #expect(try jsonString(rebuilt) == jsonString(expected))
        #expect(rebuilt.betaHeaders == original.betaHeaders)
        #expect(rebuilt.tag == original.tag)
    }

    @Test func tagIsNotEncoded() throws {
        var r = try Fixtures.request(for: .notes)
        r.tag?.reservationID = "res-1"
        #expect(!(try jsonString(r)).contains("reservation"))
        #expect(!(try jsonString(r)).contains("\"tag\""))
    }

    @Test func notesTagCarriesStyleAndFlags() throws {
        let r = try Fixtures.notesRequest(stylePrompt: "Style X", allowAdditions: false, language: "de")
        #expect(r.tag == RequestTag(step: .notes, stylePrompt: "Style X", allowAdditions: false, languageOverride: "de"))
    }

    @Test func incompleteNotesTagThrows() {
        #expect(throws: HostedRequestError.incompleteTag) {
            try HostedRequest.make(tag: RequestTag(step: .notes, stylePrompt: "S"), messages: [], model: "m")
        }
        #expect(throws: HostedRequestError.incompleteTag) {
            try HostedRequest.make(tag: RequestTag(step: .notes, allowAdditions: true), messages: [], model: "m")
        }
    }
}
