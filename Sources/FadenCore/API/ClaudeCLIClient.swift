import Foundation

public enum ClaudeCLIError: Error, Equatable, Sendable {
    /// No `claude` executable was found in the usual install locations.
    case notFound
    /// The CLI exited without a usable result; carries its error text.
    case failed(String)
}

/// Sends requests through the local Claude Code CLI (`claude -p`), so they run on the signed-in
/// Claude subscription instead of an API key. For personal use only.
///
/// The request's content blocks go to the CLI unchanged as one stream-json user message, so PDFs
/// arrive as documents just as they do over the API. Tools, customizations (`--safe-mode`) and
/// session files are off, and `ANTHROPIC_API_KEY` is removed so the CLI can't fall back to API billing.
/// Results carry the subscription's limit use, which prices the call at $0 (see `PaidCall.usd`).
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

    private let executable: URL?
    private let run: Runner

    public init(executable: URL? = ClaudeCLIClient.locate(), run: @escaping Runner = ClaudeCLIClient.runProcess) {
        self.executable = executable
        self.run = run
    }

    public func send(_ r: MessageRequest) async throws -> MessageResult {
        guard let executable else { throw ClaudeCLIError.notFound }
        let output = try await run(executable, try Self.arguments(for: r), Self.environment(for: r), try Self.input(for: r))
        try Task.checkCancellation()
        return try Self.parse(output, requestedModel: r.model)
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
            case .pdf(let base64, let title, _): .pdf(base64: base64, title: title, cache: false)
            }
        }
        var data = try JSONEncoder().encode(Line(message: Message(content: content)))
        data.append(0x0A)
        return data
    }

    // MARK: Response

    /// Reads the stream-json events: the model from the last `assistant` event, the limits from the last
    /// `rate_limit_event`, everything else from `result`.
    static func parse(_ output: Output, requestedModel: String) throws -> MessageResult {
        var result: [String: Any]?
        var model: String?
        var limits = SubscriptionLimits(session: 0, week: 0)
        for line in output.stdout.split(separator: 0x0A) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "assistant":
                if let m = (event["message"] as? [String: Any])?["model"] as? String { model = m }
            case "rate_limit_event":
                let windows = (event["rate_limit_info"] as? [String: Any])?["unifiedWindows"] as? [String: Any]
                func utilization(_ key: String) -> Double? { (windows?[key] as? [String: Any])?["utilization"] as? Double }
                limits = SubscriptionLimits(session: utilization("five_hour") ?? limits.session,
                                            week: utilization("seven_day") ?? limits.week)
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
        return MessageResult(text: text, model: usedModel, stopReason: stop ?? "end_turn", usage: usage, subscription: limits)
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
