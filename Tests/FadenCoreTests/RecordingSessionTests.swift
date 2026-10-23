import Foundation
import Testing
@testable import FadenCore

@Suite struct RecordingSessionTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession(phase: RecordingPhase = .recording) -> RecordingSession {
        RecordingSession(
            startedAt: Date(timeIntervalSince1970: 1_761_200_000.25), phase: phase, courseFolder: URL(fileURLWithPath: "/tmp/Course"))
    }

    @Test func segmentNamingSorted() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SegmentStore(root: root, sessionID: UUID())
        for _ in 1...12 {
            let url = store.nextSegmentURL()
            try Data([1]).write(to: url)
        }
        let names = store.segments().map(\.lastPathComponent)
        #expect(names == (1...12).map { String(format: "seg-%04d.caf", $0) })
    }

    @Test func nextSegmentURLDoesNotCreateFile() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SegmentStore(root: root, sessionID: UUID())
        let url = store.nextSegmentURL()
        #expect(url.lastPathComponent == "seg-0001.caf")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.segments().isEmpty)
    }

    @Test func nextSegmentAfterGapDoesNotOverwrite() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SegmentStore(root: root, sessionID: UUID())
        _ = store.nextSegmentURL()
        try Data([1]).write(to: store.dir.appendingPathComponent("seg-0001.caf"))
        try Data([3]).write(to: store.dir.appendingPathComponent("seg-0003.caf"))
        #expect(store.nextSegmentURL().lastPathComponent == "seg-0004.caf")
    }

    @Test func segmentsIgnoresOtherFiles() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SegmentStore(root: root, sessionID: UUID())
        try store.save(makeSession())
        try Data([1]).write(to: store.dir.appendingPathComponent("seg-0002.caf"))
        try Data([1]).write(to: store.dir.appendingPathComponent("junk.caf"))
        #expect(store.segments().map(\.lastPathComponent) == ["seg-0002.caf"])
    }

    @Test func unfinishedFindsCrashedSession() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let crashed = makeSession(phase: .recording)
        let done = makeSession(phase: .stopped)
        try SegmentStore(root: root, sessionID: crashed.id).save(crashed)
        try SegmentStore(root: root, sessionID: done.id).save(done)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("garbage"), withIntermediateDirectories: true)
        let found = SegmentStore.unfinished(root: root)
        #expect(found == [crashed])
    }

    @Test func unfinishedOnMissingRootIsEmpty() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("faden-none-\(UUID())")
        #expect(SegmentStore.unfinished(root: root).isEmpty)
    }

    @Test func saveLoadRoundTrip() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var s = RecordingSession(
            startedAt: Date(timeIntervalSince1970: 1_761_200_000),
            courseFolder: URL(fileURLWithPath: "/tmp/Course"),
            slides: [URL(fileURLWithPath: "/tmp/a.pdf")],
            notesFile: URL(fileURLWithPath: "/tmp/n.md"))
        _ = s.pause(at: 5, now: Date(timeIntervalSince1970: 1_761_200_100))
        let store = SegmentStore(root: root, sessionID: s.id)
        try store.save(s)
        #expect(try SegmentStore.load(dir: store.dir) == s)
    }

    @Test func discardRemovesOnlyOwnDir() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = makeSession(), b = makeSession()
        let storeA = SegmentStore(root: root, sessionID: a.id)
        let storeB = SegmentStore(root: root, sessionID: b.id)
        try storeA.save(a)
        try storeB.save(b)
        try storeA.discard()
        #expect(!FileManager.default.fileExists(atPath: storeA.dir.path))
        #expect(FileManager.default.fileExists(atPath: storeB.dir.path))
    }

    @Test func pauseResumeRecordsGap() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = makeSession()
        let r1 = s.pause(at: 1865, now: t0)
        #expect(r1)
        #expect(s.phase == .paused)
        let r2 = s.resume(at: 1865, now: t0.addingTimeInterval(155))
        #expect(r2)
        #expect(s.phase == .recording)
        #expect(s.pauses == [PauseRecord(at: 1865, began: t0, ended: t0.addingTimeInterval(155))])
        #expect(s.pauses[0].duration == 155)
    }

    @Test func resumeWhileRecordingIsNoop() {
        var s = makeSession()
        let before = s
        let r3 = s.resume(at: 10)
        #expect(!r3)
        #expect(s == before)
    }

    @Test func pauseWhilePausedIsNoop() {
        var s = makeSession()
        let r4 = s.pause(at: 10)
        #expect(r4)
        let before = s
        let r5 = s.pause(at: 20)
        #expect(!r5)
        #expect(s == before)
    }

    @Test func stopWhilePausedClosesOpenPause() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = makeSession()
        _ = s.pause(at: 10, now: t0)
        let r6 = s.stop(now: t0.addingTimeInterval(30))
        #expect(r6)
        #expect(s.phase == .stopped)
        #expect(s.pauses.last?.ended == t0.addingTimeInterval(30))
    }

    @Test func stopTwiceIsNoop() {
        var s = makeSession()
        let r7 = s.stop()
        #expect(r7)
        let before = s
        let r8 = s.stop()
        #expect(!r8)
        let r9 = s.pause(at: 1)
        #expect(!r9)
        let r10 = s.resume(at: 1)
        #expect(!r10)
        #expect(s == before)
    }
}
