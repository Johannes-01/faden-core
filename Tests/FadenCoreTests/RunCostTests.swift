import Foundation
import Testing
@testable import FadenCore

@Suite struct RunCostTests {
    private func state(notes: PaidCall? = nil, verify: PaidCall? = nil) -> PipelineState {
        var s = PipelineState(audio: [], styleID: "x", allowAdditions: true)
        s.notesCall = notes
        s.verifyCall = verify
        return s
    }

    private let opus = PaidCall(model: "claude-opus-5-5", usage: Usage(inputTokens: 152_340, outputTokens: 9_870))
    private let haiku = PaidCall(model: "claude-haiku-5-5", usage: Usage(inputTokens: 100_000, outputTokens: 2_000))

    @Test func sumsNotesAndVerify() {
        let total = state(notes: opus, verify: haiku).costUSD
        let expected = Pricing.usd(model: opus.model, usage: opus.usage)! + Pricing.usd(model: haiku.model, usage: haiku.usage)!
        #expect(abs((total ?? -1) - expected) < 1e-9)
        #expect(RunCost.text(total) == "$0.82")
    }

    @Test func notesOnly() {
        #expect(RunCost.text(state(notes: opus).costUSD) == "$0.81")
    }

    @Test func unknownModelMeansNoAmount() {
        let unknown = PaidCall(model: "mystery-model", usage: Usage(inputTokens: 1, outputTokens: 1))
        #expect(state(notes: opus, verify: unknown).costUSD == nil)
        #expect(RunCost.text(nil) == nil)
    }

    @Test func noCallsIsZero() {
        #expect(state().costUSD == 0)
    }

    @Test func readsSavedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runcost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LectureFolder.create(in: root, date: Date(), title: "L")
        try FileManager.default.createDirectory(at: folder.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state(notes: opus)).write(to: folder.stateURL)
        #expect(RunCost.text(for: folder) == "$0.81")
    }

    @Test func quitPolicy() {
        #expect(QuitPolicy.action(hasUnfinishedRecording: false, isFinishing: false, isProcessing: false) == .quitNow)
        #expect(QuitPolicy.action(hasUnfinishedRecording: true, isFinishing: false, isProcessing: false) == .confirmStopAndSave)
        #expect(QuitPolicy.action(hasUnfinishedRecording: true, isFinishing: false, isProcessing: true) == .confirmStopAndSave)
        #expect(QuitPolicy.action(hasUnfinishedRecording: false, isFinishing: true, isProcessing: false) == .waitForSave)
        #expect(QuitPolicy.action(hasUnfinishedRecording: false, isFinishing: false, isProcessing: true) == .confirmStopRun)
    }
}
