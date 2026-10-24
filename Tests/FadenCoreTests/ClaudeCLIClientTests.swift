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

    @Test func parsesTextModelUsageAndLimits() throws {
        let out = ClaudeCLIClient.Output(status: 0, stdout: Self.lines([
            #"{"type":"system","subtype":"init"}"#, Self.assistant,
            #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.08},"seven_day":{"utilization":0.61}}}}"#,
            ##"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"# Notes","usage":{"input_tokens":3,"output_tokens":900,"cache_creation_input_tokens":20000,"cache_read_input_tokens":100,"service_tier":"standard"}}"##,
        ]), stderr: Data())
        let result = try ClaudeCLIClient.parse(out, requestedModel: "x")
        #expect(result.text == "# Notes")
        #expect(result.model == "claude-opus-5-5")
        #expect(result.stopReason == "end_turn")
        #expect(result.usage == Usage(inputTokens: 3, outputTokens: 900, cacheCreationInputTokens: 20000, cacheReadInputTokens: 100))
        #expect(result.subscription == SubscriptionLimits(session: 0.08, week: 0.61))
    }

    @Test func subscriptionCallsCostNothingAndSummarizeTokensAndLimits() {
        let usage = Usage(inputTokens: 1000, outputTokens: 500, cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
        let limits = SubscriptionLimits(session: 0.124, week: 0.61)
        #expect(PaidCall(model: "claude-opus-5-5", usage: usage, subscription: limits).usd == 0)
        #expect(PaidCall(model: "claude-opus-5-5", usage: usage).usd! > 0)
        #expect(PaidCall(model: "claude-opus-5-5", usage: usage, subscription: limits).apiUSD
            == PaidCall(model: "claude-opus-5-5", usage: usage).usd)

        // Opus: 1000 × $4 + 500 × $20 = $0.014; Haiku: 1000 × $0.10 + 500 × $0.50 = $0.00035.
        var state = PipelineState(audio: [], slides: [], userNotes: nil, styleID: "C", allowAdditions: true, language: nil)
        state.notesCall = PaidCall(model: "claude-opus-5-5", usage: usage, subscription: SubscriptionLimits(session: 0.1, week: 0.6))
        state.verifyCall = PaidCall(model: "claude-haiku-5-5", usage: usage, subscription: limits)
        #expect(state.costUSD == 0)
        #expect(RunCost.summary(state) == "\(3000.formatted()) tokens · ≈ $0.01 at API prices · session 12% · week 61%")

        let header = NotesHeader(date: .now, style: "C", slides: [], audio: [], userNotes: nil,
                                 notesCall: state.notesCall!, verifyCall: state.verifyCall, verification: "ok").markdown()
        #expect(header.contains("> Cost: Claude subscription, session 12% · week 61% used after the run · ≈ $0.01 at API prices (2000 in / 1000 out tokens)"))
    }

    @Test func subscriptionRunWithUnpricedModelOmitsAPIPrice() {
        let limits = SubscriptionLimits(session: 0.1, week: 0.6)
        var state = PipelineState(audio: [], slides: [], userNotes: nil, styleID: "C", allowAdditions: true, language: nil)
        state.notesCall = PaidCall(model: "claude-unknown", usage: Usage(inputTokens: 10, outputTokens: 5), subscription: limits)
        #expect(RunCost.summary(state) == "\(15.formatted()) tokens · session 10% · week 60%")
        let header = NotesHeader(date: .now, style: "C", slides: [], audio: [], userNotes: nil,
                                 notesCall: state.notesCall!, verifyCall: nil, verification: "ok").markdown()
        #expect(!header.contains("API prices"))
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
        #expect(result.usage.outputTokens > 0)
        #expect((result.subscription?.week ?? 0) > 0, "\(String(describing: result.subscription))")
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
