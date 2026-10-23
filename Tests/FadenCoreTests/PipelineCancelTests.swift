import Foundation
import Testing
@testable import FadenCore

/// Counts arrivals; `suspend()` sleeps until the caller's task is cancelled.
actor Suspender {
    private(set) var arrivals = 0

    func suspend() async throws {
        arrivals += 1
        try await Task.sleep(for: .seconds(600))
    }

    /// Returns once `n` callers have arrived (or after about two seconds).
    func waitForArrivals(_ n: Int) async {
        for _ in 0..<200 where arrivals < n {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Like `FakeTranscriber`, but its first call suspends until cancelled.
actor SuspendingTranscriber: Transcriber {
    nonisolated let modelName = "fake-model"
    let suspender = Suspender()
    private(set) var calls = 0

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        calls += 1
        if calls == 1 { try await suspender.suspend() }
        return FakeTranscriber.speech
    }
}

/// Like `FakeClient`, but call number `suspendedCall` suspends until cancelled (and is never billed).
actor SuspendingClient: MessageSending {
    let suspender = Suspender()
    private var script: [Result<MessageResult, Error>]
    private let suspendedCall: Int
    private(set) var calls = 0

    init(_ script: [Result<MessageResult, Error>], suspendedCall: Int) {
        self.script = script
        self.suspendedCall = suspendedCall
    }

    func send(_ r: MessageRequest) async throws -> MessageResult {
        calls += 1
        if calls == suspendedCall { try await suspender.suspend() }
        guard !script.isEmpty else { throw AnthropicError.network("no scripted result") }
        return try script.removeFirst().get()
    }
}

@Suite struct PipelineCancelTests {
    static let now = Date(timeIntervalSince1970: 1_792_756_800) // 2026-10-23

    struct Env {
        let root: URL
        let folder: LectureFolder
        let styles: StyleStore
        let ledger: CostLedger

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        var ledgerExists: Bool { FileManager.default.fileExists(atPath: ledger.file.path) }

        func saved() throws -> PipelineState {
            try JSONDecoder().decode(PipelineState.self, from: Data(contentsOf: folder.stateURL))
        }

        func notesFiles() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix("notes") }
        }

        func state(audio: [URL]? = nil, slides: [URL] = [], userNotes: URL? = nil) -> PipelineState {
            PipelineState(audio: audio ?? [folder.audioURL], slides: slides, userNotes: userNotes,
                          styleID: "C-red-line", allowAdditions: true)
        }

        func pipeline(transcriber: Transcriber, client: MessageSending, folder other: LectureFolder? = nil) -> Pipeline {
            Pipeline(folder: other ?? folder, transcriber: transcriber, client: client, styles: styles, ledger: ledger,
                     now: { PipelineCancelTests.now }, duration: { _ in 60 })
        }
    }

    private func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-cancel-\(UUID().uuidString)", isDirectory: true)
        let folder = try LectureFolder.create(in: root.appendingPathComponent("Course"), date: Self.now, title: "Week 3")
        try Data("fake audio".utf8).write(to: folder.audioURL)
        let styles = StyleStore(dir: root.appendingPathComponent("styles", isDirectory: true))
        try styles.installDefaultsIfMissing()
        return Env(root: root, folder: folder, styles: styles,
                   ledger: CostLedger(file: root.appendingPathComponent("costs.jsonl")))
    }

    // MARK: - Cancel

    @Test func cancellingWhileTranscribingFailsAtTranscribingAndRetryCompletes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let transcriber = SuspendingTranscriber()
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let pipeline = env.pipeline(transcriber: transcriber, client: client)
        let audioBefore = try Data(contentsOf: env.folder.audioURL)

        let task = Task { await pipeline.run(env.state()) }
        await transcriber.suspender.waitForArrivals(1)
        task.cancel()
        let cancelled = await task.value

        #expect(cancelled.stage == .failed)
        #expect(cancelled.failedStage == .transcribing)
        #expect(cancelled.error == Pipeline.cancelledMessage)
        #expect(try env.saved() == cancelled)
        #expect(await client.calls == 0)
        #expect(!env.ledgerExists)
        #expect(try env.notesFiles().isEmpty)
        #expect(try Data(contentsOf: env.folder.audioURL) == audioBefore)

        let retried = await pipeline.retry()

        #expect(retried.stage == .done)
        #expect(await transcriber.calls == 2)
        #expect(try env.notesFiles() == ["notes.md"])
    }

    @Test func cancellingWhileWritingNotesFailsAtWritingNotesWithoutBillingAndRetryCompletes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let transcriber = FakeTranscriber()
        let client = SuspendingClient([FakeClient.notes(), FakeClient.verify()], suspendedCall: 1)
        let pipeline = env.pipeline(transcriber: transcriber, client: client)

        let task = Task { await pipeline.run(env.state()) }
        await client.suspender.waitForArrivals(1)
        task.cancel()
        let cancelled = await task.value

        #expect(cancelled.stage == .failed)
        #expect(cancelled.failedStage == .writingNotes)
        #expect(cancelled.error == "Cancelled")
        #expect(cancelled.notesCall == nil)
        #expect(cancelled.draftNotesFile == nil)
        #expect(try env.saved() == cancelled)
        #expect(!env.ledgerExists)
        #expect(try env.notesFiles().isEmpty)

        let retried = await pipeline.retry()

        #expect(retried.stage == .done)
        #expect(await transcriber.calls == 1)
        #expect(await client.calls == 3)
        #expect(try env.notesFiles() == ["notes.md"])
    }

    /// The check's failures are normally skipped; a cancellation must still stop the run.
    @Test func cancellingWhileCheckingFailsAtVerifyingAndKeepsThePaidDraft() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = SuspendingClient([FakeClient.notes(), FakeClient.verify()], suspendedCall: 2)
        let pipeline = env.pipeline(transcriber: FakeTranscriber(), client: client)

        let task = Task { await pipeline.run(env.state()) }
        await client.suspender.waitForArrivals(1)
        task.cancel()
        let cancelled = await task.value

        #expect(cancelled.stage == .failed)
        #expect(cancelled.failedStage == .verifying)
        #expect(cancelled.error == "Cancelled")
        #expect(cancelled.verificationSkipped == nil)
        #expect(cancelled.notesCall != nil)
        #expect(try env.notesFiles().isEmpty)
    }

    /// R38: the notes call returns although the run was cancelled meanwhile. The paid draft is saved and the
    /// run stops before the check; Retry never pays for the notes again.
    @Test func cancellingAsTheNotesArriveKeepsThePaidDraftAndStopsBeforeTheCheck() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        // FakeClient runs in the caller's task, so this cancels the run while the notes call is in flight.
        let client = FakeClient([FakeClient.notes()]) { call in
            if call == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let pipeline = env.pipeline(transcriber: FakeTranscriber(), client: client)

        let cancelled = await Task { await pipeline.run(env.state()) }.value

        #expect(cancelled.stage == .failed)
        #expect(cancelled.failedStage == .verifying)
        #expect(cancelled.error == "Cancelled")
        let saved = try env.saved()
        #expect(saved == cancelled)
        #expect(saved.notesCall != nil)
        #expect(saved.draftNotesFile == "draft-notes.md")
        #expect(try env.notesFiles().isEmpty)

        let retryClient = FakeClient([FakeClient.verify()])
        let retried = await env.pipeline(transcriber: FakeTranscriber(), client: retryClient).retry()

        #expect(retried.stage == .done)
        #expect(await retryClient.models == ["claude-haiku-5-5"])
    }

    // MARK: - Deleted inputs

    private func storeTranscript(_ env: Env) throws {
        var stored = FakeTranscriber.speech
        stored.model = "fake-model"
        try JSONEncoder().encode(stored).write(to: env.folder.transcriptMetaURL.creatingParent())
    }

    @Test func deletedAudioWithAStoredTranscriptContinuesFromTheTranscript() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try storeTranscript(env)
        try FileManager.default.removeItem(at: env.folder.audioURL)
        let transcriber = FakeTranscriber()
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])

        let state = await env.pipeline(transcriber: transcriber, client: client).run(env.state())

        #expect(state.stage == .done)
        #expect(await transcriber.calls == 0)
        #expect(try env.notesFiles() == ["notes.md"])
    }

    @Test func deletedAudioWithoutATranscriptFailsBeforeAnyCall() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try FileManager.default.removeItem(at: env.folder.audioURL)
        let transcriber = FakeTranscriber()
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])

        let state = await env.pipeline(transcriber: transcriber, client: client).run(env.state())

        #expect(state.stage == .failed)
        #expect(state.failedStage == .transcribing)
        #expect(state.error == "Can't process again: audio.m4a was deleted")
        #expect(await client.calls == 0)
        #expect(await transcriber.calls == 0)
    }

    @Test func deletedAudioFailsWhenReTranscriptionIsForced() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try storeTranscript(env)
        try FileManager.default.removeItem(at: env.folder.audioURL)
        var forced = env.state()
        forced.forceRetranscribe = true
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])

        let state = await env.pipeline(transcriber: FakeTranscriber(), client: client).run(forced)

        #expect(state.error == "Can't process again: audio.m4a was deleted")
        #expect(await client.calls == 0)
    }

    @Test func deletedSlidesFailBeforeAnyCall() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let slides = env.root.appendingPathComponent("deck.pdf")
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])

        let state = await env.pipeline(transcriber: FakeTranscriber(), client: client).run(env.state(slides: [slides]))

        #expect(state.stage == .failed)
        #expect(state.error == "Can't process again: deck.pdf was deleted")
        #expect(await client.calls == 0)
    }

    @Test func deletedUserNotesFailARetryBeforeAnyCall() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let notes = env.root.appendingPathComponent("my notes.md")
        try Data("mine".utf8).write(to: notes)
        let first = FakeClient([.failure(AnthropicError.streamIncomplete)])
        let pipeline = env.pipeline(transcriber: FakeTranscriber(), client: first)
        #expect(await pipeline.run(env.state(userNotes: notes)).failedStage == .writingNotes)
        try FileManager.default.removeItem(at: notes)

        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let state = await env.pipeline(transcriber: FakeTranscriber(), client: client).retry()

        #expect(state.stage == .failed)
        #expect(state.failedStage == .writingNotes)
        #expect(state.error == "Can't process again: my notes.md was deleted")
        #expect(await client.calls == 0)
    }

    @Test func aDeletedLectureFolderFailsClearlyAndIsNotRecreated() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        _ = await env.pipeline(transcriber: FakeTranscriber(), client: FakeClient([.failure(AnthropicError.streamIncomplete)]))
            .run(env.state())
        try FileManager.default.removeItem(at: env.folder.url)
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let transcriber = FakeTranscriber()

        let retried = await env.pipeline(transcriber: transcriber, client: client).retry()
        let ran = await env.pipeline(transcriber: transcriber, client: client).run(env.state())

        for state in [retried, ran] {
            #expect(state.stage == .failed)
            #expect(state.failedStage == nil)
            #expect(state.error == "The lecture folder 2026-10-23 Week 3 was deleted")
        }
        #expect(await client.calls == 0)
        #expect(await transcriber.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: env.folder.url.path))
    }
}
