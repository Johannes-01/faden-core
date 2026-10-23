import Foundation
import Testing
@testable import FadenCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FADEN_INTEGRATION"] == "1"))
struct KeychainTests {
    private let account = "anthropic-api-key-test"

    @Test func keychainRoundTrip() throws {
        defer { try? Keychain.delete(account: account) }
        try Keychain.delete(account: account)
        #expect(Keychain.read(account: account) == nil)

        try Keychain.write("sk-ant-test-1", account: account)
        #expect(Keychain.read(account: account) == "sk-ant-test-1")

        try Keychain.write("sk-ant-test-2", account: account)
        #expect(Keychain.read(account: account) == "sk-ant-test-2")

        try Keychain.delete(account: account)
        #expect(Keychain.read(account: account) == nil)
        // Deleting a missing item is not an error.
        try Keychain.delete(account: account)
    }
}
