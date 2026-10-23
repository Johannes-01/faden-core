import Foundation

/// Stands in for `AnthropicClient` when no API key is stored. Every call fails with
/// `AnthropicError.missingKey`, which the pipeline reports as "Add your Anthropic API key in Settings"
/// and keeps retryable from the notes stage.
public struct MissingKeyClient: MessageSending {
    public init() {}

    public func send(_ r: MessageRequest) async throws -> MessageResult {
        throw AnthropicError.missingKey
    }
}
