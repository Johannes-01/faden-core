import Foundation
import os

public enum ClaudeCLIError: Error, Equatable, Sendable {
    /// No `claude` executable was found in the usual install locations.
    case notFound
    /// The CLI exited without a usable result; carries its error text.
    case failed(String)
}

/// Sends requests through the local Claude Code CLI (`claude -p`), so they run on the signed-in
/// Claude subscription instead of an API key. For personal use only.
///
/// The request's content blocks go to the CLI unchanged as one stream-json user message, so slide
/// images arrive just as they do over the API. Tools, customizations (`--safe-mode`) and
/// session files are off, and `ANTHROPIC_API_KEY` is removed so the CLI can't fall back to API billing.
/// Results carry the subscription's limit use before and after the call, which prices it at $0 (see `PaidCall.usd`).
public struct ClaudeCLIClient: MessageSending {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data

        public init(status: Int32, stdout: Data, stderr: Data) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Runs the executable with these arguments, extra environment variables and stdin.
    public typealias Runner = @Sendable (URL, [String], [String: String], Data) async throws -> Output

    private static let log = Logger(subsystem: FadenCore.identifier, category: "ClaudeCLIClient")

    /// The model of the probe call that reads the limits before a run's first call.
    static let probeModel = "claude-haiku-5-5"

    private let executable: URL?
    private let run: Runner
    /// The limits after this client's last call, shared by its copies.
    private let lastLimits = OSAllocatedUnfairLock<SubscriptionLimits?>(initialState: nil)

    public init(executable: URL? = ClaudeCLIClient.locate(), run: @escaping Runner = ClaudeCLIClient.runProcess) {
        self.executable = executable
        self.run = run
    }

    /// The CLI reports the limits only after a call, so the use before it is the reading after this client's
    /// previous call (the app makes one client per run), or else a probe call's. Other use of the subscription
    /// in between, e.g. Claude Code, counts towards the call.
    public func send(_ r: MessageRequest) async throws -> MessageResult {
        guard let executable else { throw ClaudeCLIError.notFound }
        let before: SubscriptionLimits?
        if let last = lastLimits.withLock({ $0 }) {
            before = last
        } else {
            before = try await probe(executable)
        }
        let output = try await run(executable, try Self.arguments(for: r), Self.environment(for: r), try Self.input(for: r))
        try Task.checkCancellation()
        if output.status != 0 {
            let stderr = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.error("\(executable.path, privacy: .public) exited with status \(output.status): \(stderr, privacy: .public)")
        }
        let after = Self.limits(in: output.stdout)
        lastLimits.withLock { $0 = after }
        Self.log.info("Subscription limits before the call: \(Self.describe(before), privacy: .public); after: \(Self.describe(after), privacy: .public)")
        var result = try Self.parse(output, requestedModel: r.model)
        if after != nil { result.subscriptionBefore = before }
        return result
    }

    /// Reads the limits' current use with a minimal call. nil when it fails; that only loses the run's limit use.
    private func probe(_ executable: URL) async throws -> SubscriptionLimits? {
        let r = MessageRequest(model: Self.probeModel, maxTokens: 16, stream: false,
                               messages: [Message(content: [.text("Reply with ok.", cache: false)])])
        do {
            let output = try await run(executable, try Self.arguments(for: r), Self.environment(for: r), try Self.input(for: r))
            try Task.checkCancellation()
            let limits = Self.limits(in: output.stdout)
            if limits == nil { Self.log.error("Probe call reported no limits, exit status \(output.status)") }
            return limits
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Self.log.error("Probe call failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Full precision for the log, e.g. "session 0.48 (ends 2026-10-28T16:50:00Z) · week 0.18 (ends …)".
    private static func describe(_ limits: SubscriptionLimits?) -> String {
        guard let limits else { return "unknown" }
        func ends(_ date: Date?) -> String { date.map { " (ends \($0.ISO8601Format()))" } ?? "" }
        return "session \(limits.session)\(ends(limits.sessionResetsAt)) · week \(limits.week)\(ends(limits.weekResetsAt))"
    }

    // MARK: Locating the CLI

    /// A menu bar app doesn't get the login shell's PATH, so the usual install locations are checked directly.
    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Request

    static func arguments(for r: MessageRequest) throws -> [String] {
        var args = [
            "-p", "--safe-mode", "--no-session-persistence",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", r.model, "--tools", "",
        ]
        let system = (r.system ?? []).compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined(separator: "\n\n")
        if !system.isEmpty { args += ["--system-prompt", system] }
        if let effort = r.outputConfig?.effort { args += ["--effort", effort] }
        if let schema = r.outputConfig?.format?.schema {
            args += ["--json-schema", String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)]
        }
        return args
    }

    /// The CLI's own output limit stands in for the request's `max_tokens`.
    static func environment(for r: MessageRequest) -> [String: String] {
        ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": String(r.maxTokens)]
    }

    /// One stream-json line. Cache marks are dropped: the CLI sets its own breakpoints, and the API
    /// allows only four per request.
    static func input(for r: MessageRequest) throws -> Data {
        struct Line: Encodable {
            let type = "user"
            let message: Message
        }
        let content = r.messages.flatMap(\.content).map { block -> ContentBlock in
            switch block {
            case .text(let text, _): .text(text, cache: false)
            case .image(let base64, let mediaType, _): .image(base64: base64, mediaType: mediaType, cache: false)
            }
        }
        var data = try JSONEncoder().encode(Line(message: Message(content: content)))
        data.append(0x0A)
        return data
    }

    // MARK: Response

    /// The limits from the last `rate_limit_event`; nil when there is none. The CLI sends one, after the
    /// assistant message (`Fixtures/cli-haiku-ok.jsonl`).
    static func limits(in stdout: Data) -> SubscriptionLimits? {
        var limits: SubscriptionLimits?
        for line in stdout.split(separator: 0x0A) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  event["type"] as? String == "rate_limit_event" else { continue }
            let windows = (event["rate_limit_info"] as? [String: Any])?["unifiedWindows"] as? [String: Any]
            func window(_ key: String) -> [String: Any]? { windows?[key] as? [String: Any] }
            func end(_ key: String) -> Date? {
                (window(key)?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            }
            let previous = limits ?? SubscriptionLimits(session: 0, week: 0)
            limits = SubscriptionLimits(session: window("five_hour")?["utilization"] as? Double ?? previous.session,
                                        week: window("seven_day")?["utilization"] as? Double ?? previous.week,
                                        sessionResetsAt: end("five_hour") ?? previous.sessionResetsAt,
                                        weekResetsAt: end("seven_day") ?? previous.weekResetsAt)
        }
        return limits
    }

    /// Reads the stream-json events: the model from the last `assistant` event, the limits as `limits(in:)` (0
    /// when missing), everything else from `result`.
    static func parse(_ output: Output, requestedModel: String) throws -> MessageResult {
        var result: [String: Any]?
        var model: String?
        for line in output.stdout.split(separator: 0x0A) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "assistant":
                if let m = (event["message"] as? [String: Any])?["model"] as? String { model = m }
            case "result":
                result = event
            default:
                break
            }
        }

        guard let result else {
            let stderr = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeCLIError.failed(stderr.isEmpty ? "claude exited with status \(output.status)" : stderr)
        }
        let stop = result["stop_reason"] as? String
        if stop == "refusal" { throw AnthropicError.refused(category: nil) }
        if stop == "max_tokens" { throw AnthropicError.truncated }
        if result["is_error"] as? Bool == true || result["subtype"] as? String != "success" {
            let errors = (result["errors"] as? [String])?.joined(separator: "; ")
            throw ClaudeCLIError.failed(result["result"] as? String ?? errors ?? result["subtype"] as? String ?? "unknown error")
        }

        let text: String
        if let structured = result["structured_output"], !(structured is NSNull) {
            text = String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.fragmentsAllowed]), as: UTF8.self)
        } else {
            text = result["result"] as? String ?? ""
        }
        let usedModel = model ?? (result["modelUsage"] as? [String: Any])?.keys.first ?? requestedModel
        let usage = (result["usage"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(Usage.self, from: $0) } ?? Usage()
        return MessageResult(text: text, model: usedModel, stopReason: stop ?? "end_turn", usage: usage,
                             subscription: limits(in: output.stdout) ?? SubscriptionLimits(session: 0, week: 0))
    }

    // MARK: Process

    /// Runs the CLI in the temporary directory. Stdin is written and stdout and stderr are drained on their
    /// own threads, so a large request or response can't deadlock on a full pipe. Cancelling terminates it.
    public static let runProcess: Runner = { executable, arguments, extraEnvironment, stdin in
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.merge(extraEnvironment) { $1 }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A CLI that exits before reading all of stdin must fail the write, not kill the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = {
            exited.continuation.yield($0.terminationStatus)
            exited.continuation.finish()
        }
        do { try process.run() } catch { throw ClaudeCLIError.failed(error.localizedDescription) }

        return await withTaskCancellationHandler {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
            async let stdout = readToEnd(output.fileHandleForReading)
            async let stderr = readToEnd(errors.fileHandleForReading)
            let (out, err) = await (stdout, stderr)
            var status: Int32 = -1
            for await s in exited.stream { status = s }
            return Output(status: status, stdout: out, stderr: err)
        } onCancel: {
            process.terminate()
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}
