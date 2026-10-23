import Foundation

/// Stands in for `AnthropicClient` when no API key can be used. Every call fails: with
/// `AnthropicError.missingKey` when none is stored, which the pipeline reports as "Add your Anthropic API
/// key in Settings", or with `AnthropicError.keyUnreadable` when the Keychain returned an error. Either
/// way the run stays retryable from the notes stage.
public struct MissingKeyClient: MessageSending {
    private let status: APIKeyStatus

    public init(status: APIKeyStatus = .missing) {
        self.status = status
    }

    public func send(_ r: MessageRequest) async throws -> MessageResult {
        if case .unreadable(let code) = status { throw AnthropicError.keyUnreadable(status: code) }
        throw AnthropicError.missingKey
    }
}
