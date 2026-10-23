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

    @Test func dismissingAFailedRunForgetsIt() {
        var board = RunBoard()
        let a = UUID(), b = UUID()
        board.start(a, folder: folder("A"), stage: .transcribing)
        board.finish(a, folder: folder("A"), stage: .failed, error: "x")
        board.start(b, folder: folder("B"), stage: .transcribing)

        board.dismiss(b)  // running: stays
        board.dismiss(a)

        #expect(board.runs.map(\.id) == [b])
        #expect(board.unfinishedPaths == ["/Course/B"])
    }

    /// Ruling R37a: every failed run stays reachable, beyond the first three behind "+N more".
    @Test func everyFailedRunStaysReachable() {
        var board = RunBoard()
        let ids = (0..<5).map { _ in UUID() }
        for (n, id) in ids.enumerated() {
            board.start(id, folder: folder("F\(n)"), stage: .transcribing)
            board.finish(id, folder: folder("F\(n)"), stage: .failed, error: "x")
        }

        #expect(board.visible.map(\.id) == ids.reversed())
        let collapsed = board.shown(expanded: false)
        #expect(collapsed.runs.map(\.id) == Array(ids.reversed().prefix(3)))
        #expect(collapsed.more == 2)
        let expanded = board.shown(expanded: true)
        #expect(expanded.runs.count == 5)
        #expect(expanded.more == 0)
        #expect(Set(board.unfinishedPaths) == Set(board.visible.map(\.folder.url.path)))
    }

    /// Ruling R37b: a failure with no stage to resume offers no Retry.
    @Test func aFailureWithoutAStageCannotResume() {
        var board = RunBoard()
        let a = UUID(), b = UUID()
        board.start(a, folder: folder("A"), stage: .transcribing)
        board.finish(a, folder: folder("A"), stage: .failed, error: "x", canResume: false)
        board.start(b, folder: folder("B"), stage: .transcribing)
        board.finish(b, folder: folder("B"), stage: .failed, error: "y", canResume: true)

        #expect(board.runs.map(\.canResume) == [true, false])
    }

    @Test func noticingDeletedFilesDropsGoneFoldersAndMarksGoneNotes() {
        var board = RunBoard()
        let gone = UUID(), done = UUID(), running = UUID()
        board.start(gone, folder: folder("Gone"), stage: .transcribing)
        board.finish(gone, folder: folder("Gone"), stage: .failed, error: "x")
        board.start(running, folder: folder("Running"), stage: .transcribing)
        board.start(done, folder: folder("Done"), stage: .transcribing)
        let notes = URL(fileURLWithPath: "/Course/Done/notes.md")
        board.finish(done, folder: folder("Done"), stage: .done, error: nil, notes: notes)
        let existing: Set<String> = ["/Course/Done"]

        board.noticeDeletedFiles { existing.contains($0.path) }

        #expect(board.runs.map(\.id) == [done, running])
        #expect(board.latest?.notesDeleted == true)
        #expect(board.latest?.notes == nil)
        #expect(board.unfinishedPaths == ["/Course/Running"])
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
        let stuck = try makeLecture(in: course, "Stuck", stage: .failed, error: "Could not read")
        let done = try makeLecture(in: course, "Done", stage: .done)
        let gone = course.appending(path: "2026-01-01 Deleted").path

        let board = RunBoard.restored(paths: [failed.url.path, interrupted.url.path, done.url.path, gone, stuck.url.path])

        #expect(board.runs.map(\.folder.url.lastPathComponent) == [failed.url.lastPathComponent,
                                                                   interrupted.url.lastPathComponent,
                                                                   stuck.url.lastPathComponent])
        #expect(board.runs.map(\.canResume) == [true, true, false])
        #expect(board.runs.allSatisfy { $0.stage == .failed && !$0.isRunning })
        #expect(board.runs[0].error == "HTTP 500")
        #expect(board.runs[1].error == RunBoard.interruptedMessage)
        #expect(board.unfinishedPaths == [failed.url.path, interrupted.url.path, stuck.url.path])
        #expect(Set(board.visible.map(\.id)) == Set(board.runs.map(\.id)))
    }
}
