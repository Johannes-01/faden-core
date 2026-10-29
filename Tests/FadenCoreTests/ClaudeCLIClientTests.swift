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
            messages: [Message(content: [.image(base64: "QUJD", mediaType: "image/jpeg", cache: true), .text("transcript", cache: false)])],
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

    @Test func inputIsOneUserLineWithImagesAndNoCacheMarks() throws {
        let data = try ClaudeCLIClient.input(for: Self.notesRequest())
        #expect(data.last == 0x0A)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
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

    /// Recorded from `claude -p` 2.x with Faden's arguments (the `system` init line left out): the only
    /// `rate_limit_event` comes after the assistant message.
    @Test func parsesRecordedCLIOutput() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let stdout = try Data(contentsOf: dir.appending(path: "Fixtures/cli-haiku-ok.jsonl"))
        let types = stdout.split(separator: 0x0A).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["type"] as? String
        }
        #expect(types.filter { $0 == "rate_limit_event" }.count == 1)
        #expect(types.firstIndex(of: "assistant")! < types.firstIndex(of: "rate_limit_event")!)

        let result = try ClaudeCLIClient.parse(.init(status: 0, stdout: stdout, stderr: Data()), requestedModel: "x")
        #expect(result.text == "ok")
        #expect(result.model == "claude-haiku-5-5")
        #expect(result.subscription == SubscriptionLimits(
            session: 0.48, week: 0.18,
            sessionResetsAt: Date(timeIntervalSince1970: 1793189400), weekResetsAt: Date(timeIntervalSince1970: 1793548800)))
    }

    private static func limitEvent(session: Double, week: Double, sessionEnd: Double = 1793189400) -> String {
        #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":\#(session),"resetsAt":\#(sessionEnd)},"seven_day":{"utilization":\#(week),"resetsAt":1793548800}}}}"#
    }

    private static let success = #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"done"}"#

    /// A fake CLI that answers each call with the next output and records which model each call asked for.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [Data]
        private(set) var models: [String] = []

        init(_ outputs: [Data]) { self.outputs = outputs }

        var runner: ClaudeCLIClient.Runner {
            { _, args, _, _ in
                self.lock.withLock {
                    self.models.append(args[args.firstIndex(of: "--model")! + 1])
                    return ClaudeCLIClient.Output(status: 0, stdout: self.outputs.removeFirst(), stderr: Data())
                }
            }
        }
    }

    @Test func firstCallProbesTheLimitsAndLaterCallsStartFromThePreviousReading() async throws {
        let script = Script([
            Self.lines([Self.assistant, Self.limitEvent(session: 0.10, week: 0.60), Self.success]),  // probe
            Self.lines([Self.assistant, Self.limitEvent(session: 0.14, week: 0.61), Self.success]),  // notes
            Self.lines([Self.assistant, Self.limitEvent(session: 0.15, week: 0.61), Self.success]),  // check
        ])
        let client = ClaudeCLIClient(executable: URL(fileURLWithPath: "/bin/claude"), run: script.runner)
        let notes = try await client.send(Self.notesRequest())
        let check = try await client.send(Self.notesRequest())
        #expect(script.models == [ClaudeCLIClient.probeModel, "claude-opus-5-5", "claude-opus-5-5"])
        #expect(notes.subscriptionBefore?.session == 0.10)
        #expect(notes.subscription?.session == 0.14)
        #expect(check.subscriptionBefore?.session == 0.14)
        #expect(check.subscription?.session == 0.15)
    }

    @Test func failedProbeLeavesTheBeforeReadingOut() async throws {
        let script = Script([
            Self.lines([#"{"type":"result","subtype":"error_during_execution","is_error":true}"#]),
            Self.lines([Self.assistant, Self.limitEvent(session: 0.14, week: 0.61), Self.success]),
        ])
        let result = try await ClaudeCLIClient(executable: URL(fileURLWithPath: "/bin/claude"), run: script.runner)
            .send(Self.notesRequest())
        #expect(result.subscriptionBefore == nil)
        #expect(result.subscription?.session == 0.14)
        #expect(PaidCall(model: result.model, usage: result.usage, subscription: result.subscription,
                         subscriptionBefore: result.subscriptionBefore).limitUse == nil)
    }

    @Test func subscriptionCallsCostNothing() {
        let usage = Usage(inputTokens: 1000, outputTokens: 500)
        #expect(PaidCall(model: "claude-opus-5-5", usage: usage, subscription: SubscriptionLimits(session: 0.1, week: 0.6)).usd == 0)
        #expect(PaidCall(model: "claude-opus-5-5", usage: usage).usd! > 0)
    }

    private static func call(_ model: String, from before: (Double, Double)?, to after: (Double, Double),
                             sessionEnds: (Double, Double) = (1793189400, 1793189400)) -> PaidCall {
        PaidCall(model: model, usage: Usage(inputTokens: 1000, outputTokens: 500),
                 subscription: SubscriptionLimits(session: after.0, week: after.1,
                                                  sessionResetsAt: Date(timeIntervalSince1970: sessionEnds.1)),
                 subscriptionBefore: before.map { SubscriptionLimits(session: $0.0, week: $0.1,
                                                                     sessionResetsAt: Date(timeIntervalSince1970: sessionEnds.0)) })
    }

    @Test func runShowsTheLimitUseSummedOverItsCalls() {
        var state = PipelineState(audio: [], slides: [], userNotes: nil, styleID: "C", allowAdditions: true, language: nil)
        state.notesCall = Self.call("claude-opus-5-5", from: (0.10, 0.60), to: (0.13, 0.60))
        state.verifyCall = Self.call("claude-haiku-5-5", from: (0.13, 0.60), to: (0.14, 0.61))
        #expect(state.costUSD == 0)
        #expect(state.limitUse?.text == "session +4% · week +1%")
        #expect(RunCost.summary(state) == "\(3000.formatted()) tokens · session +4% · week +1%")

        let header = NotesHeader(date: .now, style: "C", slides: [], audio: [], userNotes: nil,
                                 notesCall: state.notesCall!, verifyCall: state.verifyCall, verification: "ok").markdown()
        #expect(header.contains("> Cost: Claude subscription, limit use: session +4% · week +1% (2000 in / 1000 out tokens)"))
        #expect(!header.contains("$"))
    }

    @Test func useBelowOnePercentIsNotShownAsZero() {
        #expect(LimitUse(session: 0, week: 0.004).text == "session <1% · week <1%")
        #expect(LimitUse(session: 0.006, week: 0.0149).text == "session +1% · week +1%")
        // 0.49 − 0.48 is a hair under 0.01 in floating point.
        #expect(LimitUse(before: SubscriptionLimits(session: 0.48, week: 0.1), after: SubscriptionLimits(session: 0.49, week: 0.1)).text
            == "session +1% · week <1%")
    }

    @Test func windowThatStartsOverDuringTheRunIsShownAsReset() {
        // The session's end moved: a new five-hour window started between the readings.
        let moved = Self.call("claude-opus-5-5", from: (0.10, 0.60), to: (0.12, 0.61), sessionEnds: (1793189400, 1793207400))
        #expect(moved.limitUse?.session == nil)
        #expect(abs((moved.limitUse?.week ?? 0) - 0.01) < 1e-9)
        // Use went down without a reported end.
        let dropped = LimitUse(before: SubscriptionLimits(session: 0.9, week: 0.6), after: SubscriptionLimits(session: 0.02, week: 0.61))
        #expect(dropped.session == nil)

        var state = PipelineState(audio: [], slides: [], userNotes: nil, styleID: "C", allowAdditions: true, language: nil)
        state.notesCall = moved
        state.verifyCall = Self.call("claude-haiku-5-5", from: (0.12, 0.61), to: (0.13, 0.61), sessionEnds: (1793207400, 1793207400))
        #expect(state.limitUse?.text == "session reset during run · week +1%")
    }

    @Test func oldStatesWithoutABeforeReadingShowNoLimitUse() throws {
        // A state saved before Faden recorded the before-reading and reset times.
        let json = #"{"stage":"done","audio":[],"slides":[],"styleID":"C","allowAdditions":true,"transcriptionModel":"m","forceRetranscribe":false,"titleIsPlaceholder":false,"markers":[],"notesCall":{"model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":500},"subscription":{"session":0.12,"week":0.61}}}"#
        let state = try JSONDecoder().decode(PipelineState.self, from: Data(json.utf8))
        #expect(state.ranOnSubscription)
        #expect(state.limitUse == nil)
        #expect(RunCost.summary(state) == "\(1500.formatted()) tokens")
        let header = NotesHeader(date: .now, style: "C", slides: [], audio: [], userNotes: nil,
                                 notesCall: state.notesCall!, verifyCall: nil, verification: "ok").markdown()
        #expect(header.contains("> Cost: Claude subscription (1000 in / 500 out tokens)"))
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
        // Read by the probe call before it.
        #expect(result.subscriptionBefore != nil)
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
