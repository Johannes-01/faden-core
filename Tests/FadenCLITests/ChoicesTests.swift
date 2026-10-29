import FadenCore
import FadenTranscription
import Foundation
import Security
import Testing
@testable import FadenCLI

private let ids = ["A-slide-by-slide", "B-by-topic", "C-red-line", "D-slides-and-lecture"]

@Test func styleLetterMeansItsFile() throws {
    #expect(try StyleChoice.id(for: "C", among: ids) == "C-red-line")
    #expect(try StyleChoice.id(for: "d", among: ids) == "D-slides-and-lecture")
}

@Test func fullStyleIdMatchesExactly() throws {
    #expect(try StyleChoice.id(for: "b-by-topic", among: ids) == "B-by-topic")
    #expect(try StyleChoice.id(for: "C", among: ids + ["C", "C-mine"]) == "C")
}

@Test func unknownAndAmbiguousStylesAreRefused() {
    #expect(throws: CLIError.unknownStyle("E", ids)) { try StyleChoice.id(for: "E", among: ids) }
    #expect(throws: CLIError.ambiguousStyle("C", ["C-red-line", "C-mine"])) {
        try StyleChoice.id(for: "C", among: ids + ["C-mine"])
    }
}

@Test func environmentKeyComesBeforeTheKeychain() throws {
    let client = try ClientChoice.make(subscription: false, environment: ["ANTHROPIC_API_KEY": " sk-ant-env\n"]) {
        Issue.record("the Keychain was read")
        return "sk-ant-keychain"
    }
    #expect(client is AnthropicClient)
}

@Test func keychainKeyIsUsedWithoutEnvironmentKey() throws {
    #expect(try ClientChoice.make(subscription: false, environment: ["ANTHROPIC_API_KEY": " "]) { "sk-ant-1" } is AnthropicClient)
}

@Test func noKeyFailsBeforeAnythingRuns() {
    #expect(throws: CLIError.missingKey) { try ClientChoice.make(subscription: false, environment: [:]) { nil } }
    #expect(throws: CLIError.missingKey) { try ClientChoice.make(subscription: false, environment: [:]) { " " } }
    #expect(throws: CLIError.keyUnreadable(errSecInternalError)) {
        try ClientChoice.make(subscription: false, environment: [:]) { throw CocoaError(.fileReadNoPermission) }
    }
}

@Test func subscriptionUsesTheClaudeCLI() throws {
    let client = try ClientChoice.make(subscription: true, environment: ["ANTHROPIC_API_KEY": "sk-ant-env"]) { nil }
    #expect(client is ClaudeCLIClient)
}

@Test func transcriptionModelFromVariant() {
    #expect(TranscriptionModel(variant: "small") == .fast)
    #expect(TranscriptionModel(variant: TranscriptionModel.accurate.whisperKitVariant) == .accurate)
    #expect(TranscriptionModel(variant: "") == nil)
}

@Test func processParsesItsOptions() throws {
    let command = try Faden.ProcessCommand.parse([
        "a.m4a", "b.m4a", "--out", "~/Lectures", "--slides", "1.pdf", "2.pdf", "--notes", "n.md",
        "--style", "D", "--no-additions", "--language", "de", "--model", "accurate", "--subscription",
    ])
    #expect(command.audio == ["a.m4a", "b.m4a"])
    #expect(command.slides == ["1.pdf", "2.pdf"])
    #expect(command.notes == "n.md")
    #expect(command.style == "D")
    #expect(command.noAdditions)
    #expect(command.language == "de")
    #expect(command.options.model == .accurate)
    #expect(command.options.subscription)
    #expect(Faden.ProcessCommand.fileURL("~/Lectures").path == NSHomeDirectory() + "/Lectures")
}

@Test func processNeedsAudioAndAnOutputFolder() {
    #expect(throws: (any Error).self) { try Faden.ProcessCommand.parse(["--out", "x"]) }
    #expect(throws: (any Error).self) { try Faden.ProcessCommand.parse(["a.m4a"]) }
}
