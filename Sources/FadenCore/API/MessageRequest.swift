import Foundation

/// Minimal JSON tree used to embed a JSON Schema in a request.
public indirect enum JSONValue: Encodable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// `output_config.format`: `{"type":"json_schema","schema":…}`.
public struct JSONSchemaFormat: Encodable, Sendable {
    public let schema: JSONValue

    public init(schema: JSONValue) { self.schema = schema }

    private enum CodingKeys: String, CodingKey { case type, schema }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("json_schema", forKey: .type)
        try c.encode(schema, forKey: .schema)
    }
}

public struct OutputConfig: Encodable, Sendable {
    public var effort: String?
    public var format: JSONSchemaFormat?

    public init(effort: String? = nil, format: JSONSchemaFormat? = nil) {
        self.effort = effort
        self.format = format
    }

    private enum CodingKeys: String, CodingKey { case effort, format }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(format, forKey: .format)
    }
}

public enum ContentBlock: Encodable, Sendable {
    case text(String, cache: Bool)
    case image(base64: String, mediaType: String, cache: Bool)

    private enum CodingKeys: String, CodingKey { case type, text, source, cacheControl = "cache_control" }
    private enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data }
    private struct CacheControl: Encodable { let type = "ephemeral" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let cache):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            if cache { try c.encode(CacheControl(), forKey: .cacheControl) }
        case .image(let base64, let mediaType, let cache):
            try c.encode("image", forKey: .type)
            var s = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try s.encode("base64", forKey: .type)
            try s.encode(mediaType, forKey: .mediaType)
            try s.encode(base64, forKey: .data)
            if cache { try c.encode(CacheControl(), forKey: .cacheControl) }
        }
    }
}

public struct Message: Encodable, Sendable {
    public let role = "user"
    public var content: [ContentBlock]

    public init(content: [ContentBlock]) { self.content = content }
}

public struct MessageRequest: Encodable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var stream: Bool
    public var system: [ContentBlock]?
    public var messages: [Message]
    public var outputConfig: OutputConfig?
    public var fallbacks: String?
    /// Sent as the `anthropic-beta` header; never part of the body.
    public var betaHeaders: [String]

    public init(
        model: String,
        maxTokens: Int,
        stream: Bool,
        system: [ContentBlock]? = nil,
        messages: [Message],
        outputConfig: OutputConfig? = nil,
        fallbacks: String? = nil,
        betaHeaders: [String] = []
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.stream = stream
        self.system = system
        self.messages = messages
        self.outputConfig = outputConfig
        self.fallbacks = fallbacks
        self.betaHeaders = betaHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case model, stream, system, messages, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(stream, forKey: .stream)
        try c.encodeIfPresent(system, forKey: .system)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(outputConfig, forKey: .outputConfig)
        try c.encodeIfPresent(fallbacks, forKey: .fallbacks)
    }
}
