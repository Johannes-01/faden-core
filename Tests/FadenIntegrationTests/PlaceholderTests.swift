import Foundation
import Testing
@testable import FadenCore
@testable import FadenTranscription

@Test(.enabled(if: ProcessInfo.processInfo.environment["FADEN_INTEGRATION"] == "1"))
func integrationPlaceholder() {
    #expect(Bool(true))
}
