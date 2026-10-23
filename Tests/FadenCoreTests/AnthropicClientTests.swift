import Foundation
import Testing
@testable import FadenCore

// MARK: - URLProtocol stub

struct StubResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var queue: [StubResponse] = []
        var captured: [URLRequest] = []
        var bodies: [Data] = []
    }
    private static let state = NSLock.Box(State())

    static func reset(_ responses: [StubResponse]) {
        state.withLock { $0 = State(queue: responses) }
    }
    static var requests: [URLRequest] { state.withLock { $0.captured } }
    static var bodies: [Data] { state.withLock { $0.bodies } }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 65536)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }
        let captured = request
        let capturedBody = body
        let next: StubResponse? = Self.state.withLock { s in
            s.captured.append(captured)
            s.bodies.append(capturedBody)
            return s.queue.isEmpty ? nil : s.queue.removeFirst()
        }
        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension NSLock {
    final class Box<T>: @unchecked Sendable {
        private var value: T
        private let lock = NSLock()
        init(_ v: T) { value = v }
        func withLock<R>(_ body: (inout T) -> R) -> R {
            lock.lock(); defer { lock.unlock() }
            return body(&value)
        }
    }
}

// MARK: - Helpers

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func json(_ s: String) -> Data { Data(s.utf8) }

private func streamingRequest(beta: [String] = []) -> MessageRequest {
    MessageRequest(
        model: "claude-opus-5-5",
        maxTokens: 64000,
        stream: true,
        system: [.text("sys", cache: true)],
        messages: [Message(content: [.text("hello", cache: false)])],
        outputConfig: OutputConfig(effort: "high"),
        fallbacks: "default",
        betaHeaders: beta
    )
}

private func jsonRequest() -> MessageRequest {
    MessageRequest(
        model: "claude-haiku-5-5",
        maxTokens: 4000,
        stream: false,
        messages: [Message(content: [.text("verify", cache: false)])],
        outputConfig: OutputConfig(format: JSONSchemaFormat(schema: .object(["type": .string("object")])))
    )
}

private func client(sleeps: SleepLog = SleepLog()) -> AnthropicClient {
    AnthropicClient(apiKey: "sk-test", session: StubURLProtocol.session(), sleep: { sleeps.record($0) })
}

final class SleepLog: @unchecked Sendable {
    private let box = NSLock.Box([Duration]())
    func record(_ d: Duration) { box.withLock { $0.append(d) } }
    var values: [Duration] { box.withLock { $0 } }
}

// MARK: - Tests

@Suite(.serialized)
struct AnthropicClientTests {
    @Test func requestHeadersAndBody() async throws {
        StubURLProtocol.reset([StubResponse(body: try fixture("sse-notes-ok"))])
        _ = try await client().send(streamingRequest(beta: ["server-side-fallback-2026-07-01"]))

        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        let obj = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.bodies[0]) as? [String: Any])
        #expect(obj["fallbacks"] as? String == "default")
        #expect(obj["output_config"] as? [String: String] == ["effort": "high"])
        #expect(obj["max_tokens"] as? Int == 64000)
        #expect(obj["stream"] as? Bool == true)
        for forbidden in ["temperature", "top_p", "top_k", "thinking", "tool_choice", "budget_tokens", "betaHeaders", "beta_headers"] {
            #expect(obj[forbidden] == nil)
        }
    }

    @Test func noBetaHeaderWhenEmptyAndFallbacksOmitted() async throws {
        StubURLProtocol.reset([StubResponse(body: json(nonStreamingOK))])
        _ = try await client().send(jsonRequest())
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let obj = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.bodies[0]) as? [String: Any])
        #expect(obj["fallbacks"] == nil)
        let oc = try #require(obj["output_config"] as? [String: Any])
        #expect(oc["effort"] == nil)
        let format = try #require(oc["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func pdfBlockEncoding() throws {
        let block = ContentBlock.pdf(base64: "QUJD", title: "Slides", cache: true)
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any])
        #expect(obj["type"] as? String == "document")
        #expect(obj["title"] as? String == "Slides")
        let source = try #require(obj["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "application/pdf")
        #expect(source["data"] as? String == "QUJD")
        #expect((obj["cache_control"] as? [String: String])?["type"] == "ephemeral")

        let uncached = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ContentBlock.text("x", cache: false))) as? [String: Any])
        #expect(uncached["cache_control"] == nil)
        #expect(uncached["text"] as? String == "x")
    }

    @Test func streamParsesTextAndUsage() async throws {
        StubURLProtocol.reset([StubResponse(body: try fixture("sse-notes-ok"))])
        let result = try await client().send(streamingRequest())
        #expect(result.text == "# Wi-Fi Part 4\n")
        #expect(result.model == "claude-opus-5-5")
        #expect(result.stopReason == "end_turn")
        #expect(result.usage.inputTokens == 152340)
        #expect(result.usage.outputTokens == 9870)
        #expect(result.usage.cacheReadInputTokens == 0)
        #expect(result.usage.cacheCreationInputTokens == 0)
    }

    @Test func streamCutBeforeMessageStopThrows() async throws {
        StubURLProtocol.reset([StubResponse(body: try fixture("sse-cut"))])
        await #expect(throws: AnthropicError.streamIncomplete) {
            _ = try await client().send(streamingRequest())
        }
    }

    @Test func refusalThrowsWithCategory() async throws {
        StubURLProtocol.reset([StubResponse(body: try fixture("sse-refusal"))])
        await #expect(throws: AnthropicError.refused(category: "cyber")) {
            _ = try await client().send(streamingRequest())
        }
    }

    @Test func streamMaxTokensThrowsTruncated() async throws {
        let body = String(decoding: try fixture("sse-notes-ok"), as: UTF8.self)
            .replacingOccurrences(of: "\"end_turn\"", with: "\"max_tokens\"")
        StubURLProtocol.reset([StubResponse(body: json(body))])
        await #expect(throws: AnthropicError.truncated) {
            _ = try await client().send(streamingRequest())
        }
    }

    @Test func streamErrorEventMapsToHttpStatusZero() async throws {
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"model":"m","usage":{"input_tokens":1}}}

        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


        """
        StubURLProtocol.reset([StubResponse(body: json(body))])
        await #expect(throws: AnthropicError.http(status: 0, type: "overloaded_error", message: "Overloaded")) {
            _ = try await client().send(streamingRequest())
        }
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test func unknownEventsAreIgnored() async throws {
        let body = String(decoding: try fixture("sse-notes-ok"), as: UTF8.self)
            .replacingOccurrences(of: "event: ping", with: "event: brand_new_event")
        StubURLProtocol.reset([StubResponse(body: json(body))])
        let result = try await client().send(streamingRequest())
        #expect(result.text == "# Wi-Fi Part 4\n")
    }

    @Test func retriesOn529ThenSucceeds() async throws {
        let err = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        StubURLProtocol.reset([
            StubResponse(status: 529, body: json(err)),
            StubResponse(body: try fixture("sse-notes-ok")),
        ])
        let sleeps = SleepLog()
        let result = try await client(sleeps: sleeps).send(streamingRequest())
        #expect(result.text == "# Wi-Fi Part 4\n")
        #expect(StubURLProtocol.requests.count == 2)
        #expect(sleeps.values == [.seconds(2)])
    }

    @Test func retryAfterHeaderIsHonouredAndAttemptsCapped() async throws {
        let err = json(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#)
        StubURLProtocol.reset([
            StubResponse(status: 429, headers: ["retry-after": "7"], body: err),
            StubResponse(status: 500, body: err),
            StubResponse(status: 429, body: err),
            StubResponse(body: try fixture("sse-notes-ok")),
        ])
        let sleeps = SleepLog()
        await #expect(throws: AnthropicError.http(status: 429, type: "rate_limit_error", message: "slow down")) {
            _ = try await client(sleeps: sleeps).send(streamingRequest())
        }
        #expect(StubURLProtocol.requests.count == 3)
        #expect(sleeps.values == [.seconds(7), .seconds(8)])
    }

    @Test func nonRetryableHttpErrorMapsBody() async throws {
        let err = #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#
        StubURLProtocol.reset([StubResponse(status: 400, body: json(err))])
        await #expect(throws: AnthropicError.http(status: 400, type: "invalid_request_error", message: "bad")) {
            _ = try await client().send(streamingRequest())
        }
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test func emptyKeyThrowsMissingKeyBeforeRequest() async throws {
        StubURLProtocol.reset([])
        let c = AnthropicClient(apiKey: "", session: StubURLProtocol.session())
        await #expect(throws: AnthropicError.missingKey) {
            _ = try await c.send(streamingRequest())
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    private let nonStreamingOK = """
    {"id":"msg_2","type":"message","role":"assistant","model":"claude-haiku-5-5",
     "content":[{"type":"thinking","thinking":"hm","signature":"x"},{"type":"text","text":"{\\"unsupported\\":[]}"}],
     "stop_reason":"end_turn",
     "usage":{"input_tokens":1200,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":7}}
    """

    @Test func nonStreamingParses() async throws {
        StubURLProtocol.reset([StubResponse(body: json(nonStreamingOK))])
        let result = try await client().send(jsonRequest())
        #expect(result.text == #"{"unsupported":[]}"#)
        #expect(result.model == "claude-haiku-5-5")
        #expect(result.stopReason == "end_turn")
        #expect(result.usage == Usage(inputTokens: 1200, outputTokens: 34, cacheCreationInputTokens: 5, cacheReadInputTokens: 7))
    }

    @Test func nonStreamingRefusalThrows() async throws {
        let body = #"""
        {"model":"claude-haiku-5-5","content":[],"stop_reason":"refusal",
         "stop_details":{"type":"refusal","category":"bio","explanation":"no"},
         "usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        """#
        StubURLProtocol.reset([StubResponse(body: json(body))])
        await #expect(throws: AnthropicError.refused(category: "bio")) {
            _ = try await client().send(jsonRequest())
        }
    }
}
