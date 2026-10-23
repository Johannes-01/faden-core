import Foundation
import Testing
@testable import FadenCore

@Test func coreLoads() {
    #expect(FadenCore.resources.url(forResource: "C-red-line", withExtension: "md", subdirectory: "styles") != nil)
}

@Test func resourcesPreferTheAppsResourcesFolder() throws {
    let resources = FileManager.default.temporaryDirectory.appending(path: "faden-res-\(UUID().uuidString)")
    let bundleURL = resources.appending(path: FadenCore.resourceBundleName)
    try FileManager.default.createDirectory(at: bundleURL.appending(path: "prompts"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: bundleURL.appending(path: "prompts/notes-system.md"))
    defer { try? FileManager.default.removeItem(at: resources) }

    let bundle = FadenCore.resourceBundle(mainResourceURL: resources)

    #expect(bundle.bundleURL.standardizedFileURL.path == bundleURL.standardizedFileURL.path)
    #expect(bundle.url(forResource: "notes-system", withExtension: "md", subdirectory: "prompts") != nil)
}

@Test func resourcesFallBackToTheModuleBundle() {
    let missing = FileManager.default.temporaryDirectory.appending(path: "faden-none-\(UUID().uuidString)")
    for bundle in [FadenCore.resourceBundle(mainResourceURL: missing), FadenCore.resourceBundle(mainResourceURL: nil)] {
        #expect(bundle.bundleURL.lastPathComponent == FadenCore.resourceBundleName)
        #expect(bundle.url(forResource: "C-red-line", withExtension: "md", subdirectory: "styles") != nil)
    }
}
