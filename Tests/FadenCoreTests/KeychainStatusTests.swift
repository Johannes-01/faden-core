import Foundation
import Security
import Testing
@testable import FadenCore

@Suite struct KeychainStatusTests {
    @Test func notFoundIsNoKey() throws {
        #expect(try Keychain.value(status: errSecItemNotFound, result: nil) == nil)
    }

    @Test func successReturnsTheKey() throws {
        #expect(try Keychain.value(status: errSecSuccess, result: Data("sk-ant-1".utf8) as CFData) == "sk-ant-1")
    }

    @Test func otherStatusesThrow() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            #expect(throws: KeychainError(status: status)) {
                try Keychain.value(status: status, result: nil)
            }
        }
    }

    @Test func keyStatusSeparatesMissingFromUnreadable() {
        #expect(Keychain.keyStatus { "sk-ant-1" } == .present)
        #expect(Keychain.keyStatus { nil } == .missing)
        #expect(Keychain.keyStatus { "  \n" } == .missing)
        #expect(Keychain.keyStatus { throw KeychainError(status: errSecInteractionNotAllowed) }
            == .unreadable(errSecInteractionNotAllowed))
        #expect(APIKeyStatus.present.isPresent)
        #expect(!APIKeyStatus.missing.isPresent)
        #expect(!APIKeyStatus.unreadable(-25308).isPresent)
    }

    @Test func messages() {
        #expect(APIKeyStatus.present.problem == nil)
        #expect(APIKeyStatus.missing.problem == "No API key — add one in Settings")
        #expect(APIKeyStatus.unreadable(-25308).problem == "Couldn't read the API key from the Keychain (-25308)")
    }

    @Test func unreadableKeyFailsTheNotesStageWithItsStatus() async {
        await #expect(throws: AnthropicError.keyUnreadable(status: -25308)) {
            _ = try await MissingKeyClient(status: .unreadable(-25308)).send(
                MessageRequest(model: "m", maxTokens: 1, stream: false, messages: []))
        }
        await #expect(throws: AnthropicError.missingKey) {
            _ = try await MissingKeyClient().send(MessageRequest(model: "m", maxTokens: 1, stream: false, messages: []))
        }
        #expect(Pipeline.message(for: AnthropicError.keyUnreadable(status: -25308))
            == "Couldn't read the API key from the Keychain (-25308)")
        #expect(Pipeline.message(for: AnthropicError.missingKey) == "Add your Anthropic API key in Settings")
    }
}
