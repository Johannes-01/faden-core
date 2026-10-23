import Foundation
import Testing
@testable import FadenCore

@Suite struct RunBoardTests {
    private func folder(_ name: String) -> LectureFolder {
        LectureFolder(url: URL(fileURLWithPath: "/Course/\(name)", isDirectory: true))
    }

    @Test func aRunMovesThroughItsStages() {
        var board = RunBoard()
        let id = UUID()
        board.start(id, folder: folder("A"), stage: .transcribing)
        #expect(board.isRunning)
        board.update(id, stage: .writingNotes)
        #expect(board.latest?.stage == .writingNotes)

        let renamed = folder("A renamed")
        board.finish(id, folder: renamed, stage: .done, error: nil)

        #expect(!board.isRunning)
        #expect(board.latest == RunBoard.Run(id: id, folder: renamed, stage: .done, error: nil, isRunning: false))
    }

    /// Stop while another run is processing: the older run's failure stays visible.
    @Test func anOlderRunsFailureStaysVisible() {
        var board = RunBoard()
        let older = UUID(), newer = UUID()
        board.start(older, folder: folder("Old"), stage: .writingNotes)
        board.start(newer, folder: folder("New"), stage: .transcribing)
        board.finish(older, folder: folder("Old"), stage: .failed, error: "HTTP 500")

        #expect(board.latest?.id == newer)
        #expect(board.visible.map(\.id) == [newer, older])
        #expect(board.visible.last?.error == "HTTP 500")
        #expect(board.isRunning)
    }

    @Test func olderFinishedRunsAreHidden() {
        var board = RunBoard()
        let a = UUID(), b = UUID(), c = UUID()
        board.start(a, folder: folder("A"), stage: .transcribing)
        board.finish(a, folder: folder("A"), stage: .done, error: nil)
        board.start(b, folder: folder("B"), stage: .transcribing)
        board.finish(b, folder: folder("B"), stage: .failed, error: "x")
        board.start(c, folder: folder("C"), stage: .transcribing)
        board.finish(c, folder: folder("C"), stage: .done, error: nil)

        #expect(board.visible.map(\.id) == [c, b])
    }

    @Test func retryingAFolderReplacesItsEntry() {
        var board = RunBoard()
        let first = UUID(), retry = UUID()
        board.start(first, folder: folder("A"), stage: .transcribing)
        board.finish(first, folder: folder("A"), stage: .failed, error: "x")
        board.start(retry, folder: folder("A"), stage: .verifying)

        #expect(board.runs.map(\.id) == [retry])
        #expect(board.latest?.error == nil)
    }

    @Test func unfinishedPathsListEveryRunNotDone() {
        var board = RunBoard()
        let a = UUID(), b = UUID(), c = UUID()
        board.start(a, folder: folder("A"), stage: .transcribing)
        board.start(b, folder: folder("B"), stage: .transcribing)
        board.start(c, folder: folder("C"), stage: .transcribing)
        board.finish(a, folder: folder("A"), stage: .failed, error: "x")
        board.finish(b, folder: folder("B"), stage: .done, error: nil)

        #expect(board.unfinishedPaths == ["/Course/C", "/Course/A"])
    }

    // MARK: - Restore at launch

    private func makeLecture(in course: URL, _ title: String, stage: Stage, failedStage: Stage? = nil,
                             error: String? = nil) throws -> LectureFolder {
        let folder = try LectureFolder.create(in: course, date: Date(timeIntervalSince1970: 1_792_000_000), title: title)
        var state = PipelineState(audio: [folder.audioURL], styleID: "C-red-line", allowAdditions: true)
        state.stage = stage
        state.failedStage = failedStage
        state.error = error
        try JSONEncoder().encode(state).write(to: folder.stateURL.creatingParent())
        return folder
    }

    @Test func restoreOffersRetryForUnfinishedRuns() throws {
        let course = FileManager.default.temporaryDirectory.appending(path: "faden-board-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: course) }
        let failed = try makeLecture(in: course, "Failed", stage: .failed, failedStage: .writingNotes, error: "HTTP 500")
        let interrupted = try makeLecture(in: course, "Interrupted", stage: .verifying)
        let done = try makeLecture(in: course, "Done", stage: .done)
        let gone = course.appending(path: "2026-01-01 Deleted").path

        let board = RunBoard.restored(paths: [failed.url.path, interrupted.url.path, done.url.path, gone])

        #expect(board.runs.map(\.folder.url.lastPathComponent) == [failed.url.lastPathComponent,
                                                                   interrupted.url.lastPathComponent])
        #expect(board.runs.allSatisfy { $0.stage == .failed && !$0.isRunning })
        #expect(board.runs[0].error == "HTTP 500")
        #expect(board.runs[1].error == RunBoard.interruptedMessage)
        #expect(board.unfinishedPaths == [failed.url.path, interrupted.url.path])
        #expect(Set(board.visible.map(\.id)) == Set(board.runs.map(\.id)))
    }
}
