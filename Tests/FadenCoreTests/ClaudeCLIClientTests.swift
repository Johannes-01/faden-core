import Foundation
import Testing
@testable import FadenCore

@Suite struct ClaudeCLIClientTests {
    private static func lines(_ events: [String]) -> Data { Data(events.joined(separator: "\n").utf8) }

    private static let assistant = #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}"#

    private static func notesRequest() -> MessageRequest {
        MessageRequest(
            model: "claude-opus-5-5", maxTokens: 64000, stream: true,
            system: [.text("Be precise.", cache: false)],
            messages: [Message(content: [.pdf(base64: "QUJD", title: "deck.pdf", cache: true), .text("transcript", cache: false)])],
            outputConfig: OutputConfig(effort: "high"), fallbacks: "default", betaHeaders: ["x"])
    }

    @Test func argumentsCarryModelSystemPromptAndEffortWithToolsOff() throws {
        let args = try ClaudeCLIClient.arguments(for: Self.notesRequest())
        #expect(args.starts(with: ["-p", "--safe-mode", "--no-session-persistence"]))
        #expect(args.contains("--model") && args[args.firstIndex(of: "--model")! + 1] == "claude-opus-5-5")
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args[args.firstIndex(of: "--system-prompt")! + 1] == "Be precise.")
        #expect(args[args.firstIndex(of: "--effort")! + 1] == "high")
        #expect(!args.contains("--json-schema"))
    }

    @Test func schemaIsPassedAsJSON() throws {
        let r = MessageRequest(model: "m", maxTokens: 10, stream: false, messages: [],
                               outputConfig: OutputConfig(format: JSONSchemaFormat(schema: .object(["type": .string("object")]))))
        let args = try ClaudeCLIClient.arguments(for: r)
        #expect(args[args.firstIndex(of: "--json-schema")! + 1] == #"{"type":"object"}"#)
    }

    @Test func inputIsOneUserLineWithDocumentsAndNoCacheMarks() throws {
        let data = try ClaudeCLIClient.input(for: Self.notesRequest())
        #expect(data.last == 0x0A)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["document", "text"])
        #expect(content.allSatisfy { $0["cache_control"] == nil })
    }

    @Test func outputLimitIsPassedInTheEnvironment() {
        #expect(ClaudeCLIClient.environment(for: Self.notesRequest()) == ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000"])
    }

    @Test func parsesTextModelAndZeroUsage() throws {
        let out = ClaudeCLIClient.Output(status: 0, stdout: Self.lines([
            #"{"type":"system","subtype":"init"}"#, Self.assistant,
            ##"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"# Notes"}"##,
        ]), stderr: Data())
        let result = try ClaudeCLIClient.parse(out, requestedModel: "x")
        #expect(result.text == "# Notes")
        #expect(result.model == "claude-opus-5-5")
        #expect(result.stopReason == "end_turn")
        #expect(result.usage == Usage())
    }

    @Test func structuredOutputBecomesTheText() throws {
        let out = ClaudeCLIClient.Output(status: 0, stdout: Self.lines([
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_use","result":"ignored","structured_output":{"unsupported":[]}}"#,
        ]), stderr: Data())
        let result = try ClaudeCLIClient.parse(out, requestedModel: "claude-haiku-5-5")
        #expect(try Verifier.parse(result.text) == [])
        #expect(result.model == "claude-haiku-5-5")
    }

    @Test func errorsMapToPipelineErrors() {
        func parse(_ result: String) throws { _ = try ClaudeCLIClient.parse(.init(status: 1, stdout: Data(result.utf8), stderr: Data()), requestedModel: "m") }
        #expect(throws: AnthropicError.truncated) {
            try parse(#"{"type":"result","subtype":"success","stop_reason":"max_tokens","result":"cut"}"#)
        }
        #expect(throws: AnthropicError.refused(category: nil)) {
            try parse(#"{"type":"result","subtype":"success","stop_reason":"refusal"}"#)
        }
        #expect(throws: ClaudeCLIError.failed("You've hit your limit")) {
            try parse(#"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit"}"#)
        }
        #expect(throws: ClaudeCLIError.failed("not logged in")) {
            _ = try ClaudeCLIClient.parse(.init(status: 1, stdout: Data(), stderr: Data("not logged in\n".utf8)), requestedModel: "m")
        }
    }

    @Test func missingExecutableFails() async {
        await #expect(throws: ClaudeCLIError.notFound) {
            _ = try await ClaudeCLIClient(executable: nil).send(Self.notesRequest())
        }
    }

    /// Sends the real check request through the installed CLI on the signed-in subscription. Set
    /// `FADEN_LIVE_CLI=1` to run it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FADEN_LIVE_CLI"] == "1"))
    func liveCheckRequestThroughTheInstalledCLI() async throws {
        let transcript = Transcript(segments: [TranscriptSegment(start: 0, end: 5, text: "Water boils at 100 degrees Celsius at sea level.")],
                                    markers: [], language: "en", model: "test")
        let notes = "- Water boils at 100 °C at sea level. 🗣 [00:00:00]\n- Water freezes at 50 °C. 🗣 [00:00:00]"
        let result = try await ClaudeCLIClient().send(try Verifier.request(notes: notes, transcript: transcript, slides: []))
        let findings = try Verifier.parse(result.text)
        #expect(findings.contains { $0.quote.contains("50") }, "\(result.text)")
        #expect(result.model == Verifier.model)
    }

    /// Runs a fake `claude` that echoes its stdin size and an env variable back as the result.
    @Test func runsTheProcessWithStdinAndEnvironment() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "faden-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "claude")
        try """
        #!/bin/sh
        n=$(wc -c | tr -d ' ')
        printf '{"type":"result","subtype":"success","is_error":false,"result":"%s %s %s"}\\n' "$n" "$CLAUDE_CODE_MAX_OUTPUT_TOKENS" "${ANTHROPIC_API_KEY:-unset}"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // Larger than a pipe buffer, so a writer that blocks the reader would deadlock.
        let big = String(repeating: "a", count: 1_000_000)
        let r = MessageRequest(model: "m", maxTokens: 123, stream: false, messages: [Message(content: [.text(big, cache: false)])])
        let expected = try ClaudeCLIClient.input(for: r).count
        let result = try await ClaudeCLIClient(executable: script).send(r)
        #expect(result.text == "\(expected) 123 unset")
    }
}
