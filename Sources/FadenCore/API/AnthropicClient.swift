import Foundation

public struct Usage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    /// Missing fields count as 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }
}

public struct MessageResult: Sendable {
    public var text: String
    public var model: String
    public var stopReason: String
    public var usage: Usage

    public init(text: String, model: String, stopReason: String, usage: Usage) {
        self.text = text
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
    }
}

public enum AnthropicError: Error, Equatable, Sendable {
    case missingKey
    /// The Keychain returned this error when reading the key.
    case keyUnreadable(status: Int32)
    case http(status: Int, type: String?, message: String?)
    case refused(category: String?)
    case truncated
    case streamIncomplete
    case network(String)
}

public struct AnthropicClient: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let maxAttempts = 3
    static let maxRetryAfter: Double = 60
    static let backoff: [Duration] = [.seconds(2), .seconds(8), .seconds(20)]

    private let apiKey: String
    private let session: URLSession
    private let sleep: Sleep

    public init(apiKey: String, session: URLSession = .shared) {
        self.init(apiKey: apiKey, session: session, sleep: { try await Task.sleep(for: $0) })
    }

    public init(apiKey: String, session: URLSession = .shared, sleep: @escaping Sleep) {
        self.apiKey = apiKey
        self.session = session
        self.sleep = sleep
    }

    public func send(_ r: MessageRequest) async throws -> MessageResult {
        guard !apiKey.isEmpty else { throw AnthropicError.missingKey }
        let request = try makeURLRequest(r)
        return r.stream ? try await sendStreaming(request) : try await sendNonStreaming(request)
    }

    // MARK: Request

    private func makeURLRequest(_ r: MessageRequest) throws -> URLRequest {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !r.betaHeaders.isEmpty {
            req.setValue(r.betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONEncoder().encode(r)
        return req
    }

    // MARK: Retry

    private static func isRetryable(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// Errors where the request can't have reached the API, so a retry can't bill twice. A timeout or a
    /// dropped connection may come after the server accepted (and billed) the request, so those aren't retried.
    static func neverReachedServer(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet: true
        default: false
        }
    }

    private func delay(forFailedAttempt attempt: Int, response: HTTPURLResponse?) -> Duration {
        if let value = response?.value(forHTTPHeaderField: "retry-after"), let secs = Double(value), secs.isFinite, secs >= 0 {
            return .seconds(min(secs, Self.maxRetryAfter))
        }
        return Self.backoff[min(attempt, Self.backoff.count - 1)]
    }

    private static func httpError(status: Int, body: Data) -> AnthropicError {
        struct Body: Decodable {
            struct Inner: Decodable { var type: String?; var message: String? }
            var error: Inner?
        }
        let parsed = try? JSONDecoder().decode(Body.self, from: body)
        return .http(status: status, type: parsed?.error?.type, message: parsed?.error?.message)
    }

    // MARK: Non-streaming

    private func sendNonStreaming(_ request: URLRequest) async throws -> MessageResult {
        var attempt = 0
        while true {
            attempt += 1
            let data: Data
            let http: HTTPURLResponse
            do {
                let (d, resp) = try await session.data(for: request)
                guard let h = resp as? HTTPURLResponse else { throw AnthropicError.network("Non-HTTP response") }
                data = d
                http = h
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                if Self.neverReachedServer(error), attempt < Self.maxAttempts {
                    try await sleep(delay(forFailedAttempt: attempt - 1, response: nil))
                    continue
                }
                throw AnthropicError.network(error.localizedDescription)
            }
            if (200..<300).contains(http.statusCode) {
                return try Self.parseNonStreaming(data)
            }
            if Self.isRetryable(status: http.statusCode), attempt < Self.maxAttempts {
                try await sleep(delay(forFailedAttempt: attempt - 1, response: http))
                continue
            }
            throw Self.httpError(status: http.statusCode, body: data)
        }
    }

    private static func parseNonStreaming(_ data: Data) throws -> MessageResult {
        struct Block: Decodable { var type: String; var text: String? }
        struct Details: Decodable { var category: String? }
        struct Body: Decodable {
            var model: String?
            var content: [Block]?
            var stopReason: String?
            var stopDetails: Details?
            var usage: Usage?
            enum CodingKeys: String, CodingKey {
                case model, content, usage
                case stopReason = "stop_reason"
                case stopDetails = "stop_details"
            }
        }
        let body: Body
        do { body = try JSONDecoder().decode(Body.self, from: data) }
        catch { throw AnthropicError.network("Unreadable response: \(error.localizedDescription)") }
        let stop = body.stopReason ?? ""
        try checkStop(stop, category: body.stopDetails?.category)
        let text = (body.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        return MessageResult(text: text, model: body.model ?? "", stopReason: stop, usage: body.usage ?? Usage())
    }

    private static func checkStop(_ reason: String, category: String?) throws {
        if reason == "refusal" { throw AnthropicError.refused(category: category) }
        if reason == "max_tokens" { throw AnthropicError.truncated }
    }

    // MARK: Streaming

    private func sendStreaming(_ request: URLRequest) async throws -> MessageResult {
        var attempt = 0
        while true {
            attempt += 1
            let bytes: URLSession.AsyncBytes
            let http: HTTPURLResponse
            do {
                let (b, resp) = try await session.bytes(for: request)
                guard let h = resp as? HTTPURLResponse else { throw AnthropicError.network("Non-HTTP response") }
                bytes = b
                http = h
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                if Self.neverReachedServer(error), attempt < Self.maxAttempts {
                    try await sleep(delay(forFailedAttempt: attempt - 1, response: nil))
                    continue
                }
                throw AnthropicError.network(error.localizedDescription)
            }

            guard (200..<300).contains(http.statusCode) else {
                var body = Data()
                do { for try await byte in bytes { body.append(byte) } } catch { /* keep what we have */ }
                if Self.isRetryable(status: http.statusCode), attempt < Self.maxAttempts {
                    try await sleep(delay(forFailedAttempt: attempt - 1, response: http))
                    continue
                }
                throw Self.httpError(status: http.statusCode, body: body)
            }

            // Response bytes are consumed from here on: no retries.
            return try await Self.consume(bytes)
        }
    }

    private struct StreamEvent: Decodable {
        struct OutputUsage: Decodable { var output_tokens: Int? }
        struct Message: Decodable { var model: String?; var usage: Usage? }
        struct Delta: Decodable {
            struct Details: Decodable { var category: String? }
            var type: String?
            var text: String?
            var stop_reason: String?
            var stop_details: Details?
        }
        struct ErrorBody: Decodable { var type: String?; var message: String? }
        var type: String
        var message: Message?
        var delta: Delta?
        var usage: OutputUsage?
        var error: ErrorBody?
    }

    private static func consume(_ bytes: URLSession.AsyncBytes) async throws -> MessageResult {
        var text = ""
        var model = ""
        var usage = Usage()
        var stopReason = ""
        var category: String?
        var finished = false
        let decoder = JSONDecoder()

        do {
            // Only `data:` lines matter: each payload carries its own `type`, so `event:` lines
            // and blank separators (which AsyncLineSequence may drop) are not needed.
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).drop(while: { $0 == " " })
                guard let event = try? decoder.decode(StreamEvent.self, from: Data(payload.utf8)) else { continue }
                switch event.type {
                case "message_start":
                    model = event.message?.model ?? model
                    if let u = event.message?.usage { usage = u }
                case "content_block_delta":
                    if event.delta?.type == "text_delta", let t = event.delta?.text { text += t }
                case "message_delta":
                    if let r = event.delta?.stop_reason { stopReason = r }
                    if let c = event.delta?.stop_details?.category { category = c }
                    if let out = event.usage?.output_tokens { usage.outputTokens = out }
                case "message_stop":
                    finished = true
                case "error":
                    throw AnthropicError.http(status: 0, type: event.error?.type, message: event.error?.message)
                default:
                    break
                }
                if finished { break }
            }
        } catch let error as AnthropicError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw AnthropicError.network(error.localizedDescription)
        }

        // A refusal can arrive with a clean message_stop; check it before demanding completeness.
        if stopReason == "refusal" { throw AnthropicError.refused(category: category) }
        // message_stop without a stop_reason means a message_delta was lost or malformed.
        guard finished, !stopReason.isEmpty else { throw AnthropicError.streamIncomplete }
        try checkStop(stopReason, category: category)
        return MessageResult(text: text, model: model, stopReason: stopReason, usage: usage)
    }
}
