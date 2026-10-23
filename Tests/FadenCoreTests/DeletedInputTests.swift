import Foundation
import Testing
@testable import FadenCore

@Suite struct DeletedInputTests {
    private let audio = URL(fileURLWithPath: "/L/audio.m4a")
    private let slides = URL(fileURLWithPath: "/S/deck.pdf")
    private let notes = URL(fileURLWithPath: "/S/mine.md")

    private func state(force: Bool = false) -> PipelineState {
        PipelineState(audio: [audio], slides: [slides], userNotes: notes, styleID: "C", allowAdditions: true,
                      forceRetranscribe: force)
    }

    private func message(_ s: PipelineState, at stage: Stage, reusable: Bool, gone: [URL]) -> String? {
        s.deletedInputMessage(startingAt: stage, transcriptReusable: reusable) { !gone.contains($0) }
    }

    @Test func nothingDeleted() {
        #expect(message(state(), at: .transcribing, reusable: false, gone: []) == nil)
    }

    @Test func deletedAudioIsNeededOnlyToTranscribeAgain() {
        #expect(message(state(), at: .transcribing, reusable: true, gone: [audio]) == nil)
        #expect(message(state(), at: .writingNotes, reusable: false, gone: [audio]) == nil)
        #expect(message(state(), at: .transcribing, reusable: false, gone: [audio])
            == "Can't process again: audio.m4a was deleted")
        #expect(message(state(force: true), at: .transcribing, reusable: true, gone: [audio])
            == "Can't process again: audio.m4a was deleted")
    }

    @Test func deletedSlidesAreNeededUntilTheCheck() {
        for stage in [Stage.transcribing, .writingNotes, .verifying] {
            #expect(message(state(), at: stage, reusable: true, gone: [slides]) == "Can't process again: deck.pdf was deleted")
        }
        #expect(message(state(), at: .saving, reusable: true, gone: [slides]) == nil)
    }

    @Test func deletedNotesFileIsNeededUntilTheNotesAreWritten() {
        for stage in [Stage.transcribing, .writingNotes] {
            #expect(message(state(), at: stage, reusable: true, gone: [notes]) == "Can't process again: mine.md was deleted")
        }
        #expect(message(state(), at: .verifying, reusable: true, gone: [notes]) == nil)
    }
}
