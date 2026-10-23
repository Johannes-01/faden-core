import Foundation
import Testing
@testable import FadenCore

@Test func coreLoads() {
    #expect(Bundle.module.url(forResource: "C-red-line", withExtension: "md", subdirectory: "styles") != nil)
}
