import Foundation
import Testing
@testable import FadenCore

/// Counts calls and returns a canned transcript.
actor FakeTranscriber: Transcriber {
    nonisolated let modelName: String
    private let transcript: Transcript
    private(set) var calls = 0

    init(modelName: String = "fake-model", transcript: Transcript = FakeTranscriber.speech) {
        self.modelName = modelName
        self.transcript = transcript
    }

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        calls += 1
        var t = transcript
        t.model = modelName
        return t
    }

    static let speech = Transcript(
        segments: [
            TranscriptSegment(start: 0, end: 30, text: String(repeating: "Eigenvalues describe how a matrix stretches space. ", count: 3)),
            TranscriptSegment(start: 30, end: 60, text: String(repeating: "The determinant is the product of the eigenvalues. ", count: 3)),
        ],
        markers: [], language: "en", model: "fake-model")

    static let silence = Transcript(
        segments: [TranscriptSegment(start: 0, end: 5, text: "uh")], markers: [], language: nil, model: "fake-model")
}

/// Suspends callers of `wait()` until `open()`.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    /// Returns once `n` callers have arrived (or after about two seconds).
    func waitForArrivals(_ n: Int) async {
        for _ in 0..<200 where arrivals < n {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Returns scripted results or errors, one per call, in order. Call number `gatedCall` waits on `gate`.
actor FakeClient: MessageSending {
    private var script: [Result<MessageResult, Error>]
    private let onCall: @Sendable (Int) -> Void
    private let gate: Gate?
    private let gatedCall: Int
    private(set) var calls = 0
    private(set) var models: [String] = []

    init(_ script: [Result<MessageResult, Error>], gate: Gate? = nil, gatedCall: Int = 0,
         onCall: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.script = script
        self.gate = gate
        self.gatedCall = gatedCall
        self.onCall = onCall
    }

    func send(_ r: MessageRequest) async throws -> MessageResult {
        calls += 1
        models.append(r.model)
        onCall(calls)
        let result = script.isEmpty ? nil : script.removeFirst()
        if calls == gatedCall, let gate { await gate.wait() }
        guard let result else { throw AnthropicError.network("no scripted result") }
        return try result.get()
    }

    static let notesText = "# Linear Algebra\n\n- 🗣 Eigenvalues describe stretching.\n- 🗣 The determinant is a product.\n"

    static func notes(_ text: String = notesText) -> Result<MessageResult, Error> {
        .success(MessageResult(text: text, model: "claude-opus-5-5", stopReason: "end_turn",
                               usage: Usage(inputTokens: 10_000, outputTokens: 2_000)))
    }

    static func verify(_ json: String = #"{"unsupported":[{"quote":"determinant","reason":"not said"}]}"#)
        -> Result<MessageResult, Error> {
        .success(MessageResult(text: json, model: "claude-haiku-5-5", stopReason: "end_turn",
                               usage: Usage(inputTokens: 12_000, outputTokens: 100)))
    }
}

@Suite struct PipelineTests {
    struct Env {
        let root: URL
        let course: URL
        let folder: LectureFolder
        let styles: StyleStore
        let ledger: CostLedger

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func ledgerLines() throws -> [String] {
            guard FileManager.default.fileExists(atPath: ledger.file.path) else { return [] }
            return try String(contentsOf: ledger.file, encoding: .utf8).split(separator: "\n").map(String.init)
        }
    }

    static let now = Date(timeIntervalSince1970: 1_792_756_800) // 2026-10-23

    private func makeEnv(title: String = "Lecture") throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-pipeline-\(UUID().uuidString)", isDirectory: true)
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let folder = try LectureFolder.create(in: course, date: Self.now, title: title)
        try Data("fake audio".utf8).write(to: folder.audioURL)
        let styles = StyleStore(dir: root.appendingPathComponent("styles", isDirectory: true))
        try styles.installDefaultsIfMissing()
        return Env(root: root, course: course, folder: folder, styles: styles,
                   ledger: CostLedger(file: root.appendingPathComponent("costs.jsonl")))
    }

    private func makeState(_ env: Env, audio: [URL]? = nil, placeholder: Bool = false) -> PipelineState {
        PipelineState(audio: audio ?? [env.folder.audioURL], styleID: "C-red-line", allowAdditions: true,
                      titleIsPlaceholder: placeholder)
    }

    private func makePipeline(_ env: Env, folder: LectureFolder? = nil, transcriber: Transcriber,
                              client: MessageSending) -> Pipeline {
        Pipeline(folder: folder ?? env.folder, transcriber: transcriber, client: client, styles: env.styles,
                 ledger: env.ledger, now: { PipelineTests.now }, duration: { _ in 60 })
    }

    @Test func happyPathWritesNotesWithHeader() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(), client: client)

        let state = await pipeline.run(makeState(env))

        #expect(state.stage == .done)
        #expect(state.error == nil)
        #expect(state.transcriptionModel == "fake-model")
        let notes = try String(contentsOf: env.folder.notesURL, encoding: .utf8)
        let lines = notes.components(separatedBy: "\n")
        #expect(lines[0] == "# Linear Algebra")
        #expect(lines[2].hasPrefix("> Generated by Faden"))
        #expect(lines[2].contains("style C"))
        #expect(notes.contains("> Verification: ok, 1 flagged"))
        #expect(notes.contains("- 🗣 The determinant is a product. ⚠️ not found in sources"))
        #expect(notes.contains("audio audio.m4a"))
        // Opus 10k in × $4 + 2k out × $20 = $0.08; Haiku 12k × $0.10 + 100 × $0.50 ≈ $0.00125 → $0.08
        #expect(notes.contains("> Cost: $0.08 (22000 in / 2100 out tokens)"))
        #expect(try env.ledgerLines().count == 2)
        #expect(await client.models == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(FileManager.default.fileExists(atPath: env.folder.transcriptURL.path))
        #expect(FileManager.default.fileExists(atPath: env.folder.transcriptMetaURL.path))
        let saved = try JSONDecoder().decode(PipelineState.self, from: Data(contentsOf: env.folder.stateURL))
        #expect(saved.stage == .done)
    }

    @Test func progressReportsEachStage() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(),
                                    client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
        let collector = Task {
            var seen: [Stage] = []
            for await stage in pipeline.progress {
                seen.append(stage)
                if stage == .done || stage == .failed { break }
            }
            return seen
        }
        _ = await pipeline.run(makeState(env))
        #expect(await collector.value == [.transcribing, .writingNotes, .verifying, .saving, .done])
    }

    @Test func emptyTranscriptSkipsAPI() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(transcript: FakeTranscriber.silence),
                                    client: client)

        let state = await pipeline.run(makeState(env))

        #expect(await client.calls == 0)
        #expect(state.stage == .failed)
        #expect(state.failedStage == .transcribing)
        #expect(state.error == "No speech found")
        #expect(!FileManager.default.fileExists(atPath: env.folder.notesURL.path))
    }

    @Test func retryResumesAtNotesStage() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let transcriber = FakeTranscriber()
        let client = FakeClient([.failure(AnthropicError.streamIncomplete), FakeClient.notes(), FakeClient.verify()])
        let pipeline = makePipeline(env, transcriber: transcriber, client: client)

        let first = await pipeline.run(makeState(env))
        #expect(first.stage == .failed)
        #expect(first.failedStage == .writingNotes)
        #expect(first.error?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: env.folder.notesURL.path))
        let saved = try JSONDecoder().decode(PipelineState.self, from: Data(contentsOf: env.folder.stateURL))
        #expect(saved.failedStage == .writingNotes)

        let second = await pipeline.retry()

        #expect(second.stage == .done)
        #expect(second.error == nil)
        #expect(await transcriber.calls == 1)
        #expect(FileManager.default.fileExists(atPath: env.folder.notesURL.path))
    }

    @Test func retryAtSavingNeverCallsNotesModelAgain() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let folderPath = env.folder.url.path
        // While the verifier is called, make the lecture folder read-only so saving notes.md fails.
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()]) { call in
            if call == 2 {
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folderPath)
            }
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderPath) }
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(), client: client)

        let first = await pipeline.run(makeState(env))
        #expect(first.stage == .failed)
        #expect(first.failedStage == .saving)
        #expect(FileManager.default.fileExists(
            atPath: env.folder.stateURL.deletingLastPathComponent().appendingPathComponent("draft-notes.md").path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderPath)
        let second = await pipeline.retry()

        #expect(second.stage == .done)
        #expect(await client.calls == 2)
        #expect(try env.ledgerLines().count == 2)
        let notes = try String(contentsOf: env.folder.notesURL, encoding: .utf8)
        #expect(notes.contains("> Verification: ok, 1 flagged"))
        #expect(notes.contains("> Cost: $0.08"))
    }

    @Test func savingUsesTheStyleNameFromTheNotesStage() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let styleFile = env.styles.dir.appendingPathComponent("C-red-line.md")
        // The style is deleted after the notes call, e.g. while the check runs.
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()]) { call in
            if call == 2 { try? FileManager.default.removeItem(at: styleFile) }
        }
        let state = await makePipeline(env, transcriber: FakeTranscriber(), client: client).run(makeState(env))

        #expect(state.stage == .done)
        #expect(state.styleName == "C")
        let notes = try String(contentsOf: env.folder.notesURL, encoding: .utf8)
        #expect(notes.contains(" · style C · "))
    }

    /// "Process again" with the inputs of a paid draft: the planner carries the draft's fields over.
    private func processAgainState(_ env: Env, from saved: PipelineState) -> PipelineState {
        var s = makeState(env)
        s.language = saved.language
        return s.carryingPaidDraft(from: saved)
    }

    /// A first run whose notes (and check, unless `verify` says otherwise) are paid for, but whose saving
    /// fails because the lecture folder is read-only: a failed run that still holds its paid draft.
    private func failedRunWithAPaidDraft(_ env: Env, verify: Result<MessageResult, Error> = FakeClient.verify())
        async -> PipelineState {
        let folderPath = env.folder.url.path
        let client = FakeClient([FakeClient.notes(), verify]) { call in
            if call == 2 {
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folderPath)
            }
        }
        let first = await makePipeline(env, transcriber: FakeTranscriber(), client: client).run(makeState(env))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderPath)
        return first
    }

    @Test func processAgainOfAFailedRunResumesFromItsPaidDraftWithoutPaying() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let first = await failedRunWithAPaidDraft(env)
        #expect(first.stage == .failed)
        #expect(first.failedStage == .saving)

        let transcriber = FakeTranscriber()
        let client = FakeClient([])
        let pipeline = makePipeline(env, transcriber: transcriber, client: client)
        let again = await pipeline.run(processAgainState(env, from: first))

        #expect(again.stage == .done)
        #expect(await client.calls == 0)
        #expect(await transcriber.calls == 0)
        #expect(try env.ledgerLines().count == 2)
        let notes = try String(contentsOf: env.folder.notesURL, encoding: .utf8)
        #expect(notes.contains("> Verification: ok, 1 flagged"))
        #expect(notes.contains("> Cost: $0.08"))
    }

    /// Ruling R35: every Process again of a finished lecture costs the same again (spec §5).
    @Test func processAgainOfADoneLectureWritesFreshNotes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let first = await makePipeline(env, transcriber: FakeTranscriber(),
                                       client: FakeClient([FakeClient.notes(), FakeClient.verify()])).run(makeState(env))
        #expect(first.stage == .done)

        let client = FakeClient([FakeClient.notes("# Fresh\n\n- 🗣 New notes.\n"), FakeClient.verify(#"{"unsupported":[]}"#)])
        let again = await makePipeline(env, transcriber: FakeTranscriber(), client: client)
            .run(processAgainState(env, from: first))

        #expect(again.stage == .done)
        #expect(await client.models == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(try env.ledgerLines().count == 4)
        let names = try FileManager.default.contentsOfDirectory(atPath: env.folder.url.path)
        let rerun = try #require(names.first { $0.hasPrefix("notes (re-run ") })
        let notes = try String(contentsOf: env.folder.url.appendingPathComponent(rerun), encoding: .utf8)
        #expect(notes.contains("- 🗣 New notes."))
    }

    @Test func processAgainOnlyRunsTheCheckWhenItHadNoCall() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let first = await failedRunWithAPaidDraft(env, verify: .failure(AnthropicError.http(status: 500, type: nil, message: nil)))
        #expect(first.stage == .failed)
        #expect(first.verificationSkipped == "skipped (HTTP 500)")

        let client = FakeClient([FakeClient.verify()])
        let again = await makePipeline(env, transcriber: FakeTranscriber(), client: client)
            .run(processAgainState(env, from: first))

        #expect(again.stage == .done)
        #expect(await client.models == ["claude-haiku-5-5"])
    }

    @Test func processAgainPaysWhenTheDraftCantBeReused() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let first = await makePipeline(env, transcriber: FakeTranscriber(),
                                       client: FakeClient([FakeClient.notes(), FakeClient.verify()])).run(makeState(env))

        // Another speech model: the transcript and so the draft are redone.
        let other = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let otherModel = await makePipeline(env, transcriber: FakeTranscriber(modelName: "other-model"), client: other)
            .run(processAgainState(env, from: first))
        #expect(otherModel.stage == .done)
        #expect(await other.calls == 2)

        // The draft file is gone.
        try FileManager.default.removeItem(at: env.folder.stateURL.deletingLastPathComponent()
            .appendingPathComponent("draft-notes.md"))
        let missing = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let noDraft = await makePipeline(env, transcriber: FakeTranscriber(modelName: "other-model"), client: missing)
            .run(processAgainState(env, from: otherModel))
        #expect(noDraft.stage == .done)
        #expect(await missing.calls == 2)
    }

    @Test func retryAfterSuccessDoesNothing() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = FakeClient([FakeClient.notes(), FakeClient.verify(), FakeClient.notes(), FakeClient.verify()])
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(), client: client)
        _ = await pipeline.run(makeState(env))
        let before = try FileManager.default.contentsOfDirectory(atPath: env.folder.url.path).sorted()

        let state = await pipeline.retry()

        #expect(state.stage == .done)
        #expect(await client.calls == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.folder.url.path).sorted() == before)
    }

    @Test func retryOfFailureWithoutStageDoesNothing() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        var state = makeState(env)
        state.stage = .failed
        state.error = "Could not read the saved progress"
        try JSONEncoder().encode(state).write(to: env.folder.stateURL.creatingParent())
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()])
        let transcriber = FakeTranscriber()

        let result = await makePipeline(env, transcriber: transcriber, client: client).retry()

        #expect(result == state)
        #expect(await client.calls == 0)
        #expect(await transcriber.calls == 0)
    }

    @Test func retryResumesAtVerifying() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try JSONEncoder().encode(FakeTranscriber.speech).write(to: env.folder.transcriptMetaURL.creatingParent())
        let fadenDir = env.folder.stateURL.deletingLastPathComponent()
        try FakeClient.notesText.write(to: fadenDir.appendingPathComponent("draft-notes.md"),
                                       atomically: true, encoding: .utf8)
        var state = makeState(env)
        state.stage = .failed
        state.failedStage = .verifying
        state.transcriptionModel = "fake-model"
        state.draftNotesFile = "draft-notes.md"
        state.notesCall = PaidCall(model: "claude-opus-5-5", usage: Usage(inputTokens: 10_000, outputTokens: 2_000))
        try JSONEncoder().encode(state).write(to: env.folder.stateURL)
        let client = FakeClient([FakeClient.verify()])
        let transcriber = FakeTranscriber()

        let result = await makePipeline(env, transcriber: transcriber, client: client).retry()

        #expect(result.stage == .done)
        #expect(await client.calls == 1)
        #expect(await client.models == ["claude-haiku-5-5"])
        #expect(await transcriber.calls == 0)
        let notes = try String(contentsOf: env.folder.notesURL, encoding: .utf8)
        #expect(notes.contains("> Verification: ok, 1 flagged"))
        // $0.08 notes + $0.00125 check, and both calls' tokens.
        #expect(notes.contains("> Cost: $0.08 (22000 in / 2100 out tokens)"))
    }

    @Test func overlappingRunAndRetryDoNothing() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let gate = Gate()
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()], gate: gate, gatedCall: 1)
        let transcriber = FakeTranscriber()
        let pipeline = makePipeline(env, transcriber: transcriber, client: client)
        let first = Task { await pipeline.run(makeState(env)) }
        await gate.waitForArrivals(1)

        let second = await pipeline.run(makeState(env))
        let retried = await pipeline.retry()

        #expect(second.stage == .writingNotes)
        #expect(retried.stage == .writingNotes)
        #expect(await client.calls == 1)
        #expect(await transcriber.calls == 1)
        await gate.open()
        #expect(await first.value.stage == .done)
        #expect(await client.calls == 2)
        let notes = try FileManager.default.contentsOfDirectory(atPath: env.folder.url.path)
            .filter { $0.hasPrefix("notes") }
        #expect(notes == ["notes.md"])
    }

    @Test func notesCallIsPersistedBeforeVerifying() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let gate = Gate()
        let client = FakeClient([FakeClient.notes(), FakeClient.verify()], gate: gate, gatedCall: 2)
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(), client: client)
        let run = Task { await pipeline.run(makeState(env)) }
        await gate.waitForArrivals(1)

        let saved = try JSONDecoder().decode(PipelineState.self, from: Data(contentsOf: env.folder.stateURL))

        #expect(saved.stage == .verifying)
        #expect(saved.draftNotesFile == "draft-notes.md")
        #expect(saved.notesCall?.model == "claude-opus-5-5")
        await gate.open()
        #expect(await run.value.stage == .done)
        let done = try JSONDecoder().decode(PipelineState.self, from: Data(contentsOf: env.folder.stateURL))
        #expect(done.verifyCall?.model == "claude-haiku-5-5")
        #expect(done.findings?.count == 1)
    }

    @Test func verifyFailureStillSaves() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = FakeClient([
            FakeClient.notes(),
            .failure(AnthropicError.http(status: 500, type: "api_error", message: "Internal server error")),
        ])
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(), client: client)

        let state = await pipeline.run(makeState(env))

        #expect(state.stage == .done)
        let notes = try String(contentsOf: env.folder.notesURL, encoding: .utf8)
        #expect(notes.contains("> Verification: skipped"))
        #expect(!notes.contains("product. ⚠️"))
        #expect(try env.ledgerLines().count == 1)
    }

    @Test func unreadableVerifyResponseIsSkippedButBilled() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = FakeClient([FakeClient.notes(), FakeClient.verify("not json")])
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(), client: client)

        let state = await pipeline.run(makeState(env))

        #expect(state.stage == .done)
        let notes = try String(contentsOf: env.folder.notesURL, encoding: .utf8)
        #expect(notes.contains("> Verification: skipped ("))
        #expect(try env.ledgerLines().count == 2)
    }

    @Test func rerunNeverOverwritesEditedNotes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = FakeClient([FakeClient.notes(), FakeClient.verify(), FakeClient.notes(), FakeClient.verify()])
        _ = await makePipeline(env, transcriber: FakeTranscriber(), client: client).run(makeState(env))
        try "my edits".write(to: env.folder.notesURL, atomically: true, encoding: .utf8)

        let state = await makePipeline(env, transcriber: FakeTranscriber(), client: client).run(makeState(env))

        #expect(state.stage == .done)
        #expect(try String(contentsOf: env.folder.notesURL, encoding: .utf8) == "my edits")
        let names = try FileManager.default.contentsOfDirectory(atPath: env.folder.url.path)
        #expect(names.contains { $0.hasPrefix("notes (re-run ") && $0.hasSuffix(").md") })
    }

    @Test func refusalMessage() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let client = FakeClient([.failure(AnthropicError.refused(category: "cyber"))])
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(), client: client)

        let state = await pipeline.run(makeState(env))

        #expect(state.stage == .failed)
        #expect(state.failedStage == .writingNotes)
        #expect(state.error == "The model declined this lecture (category: cyber)")
        #expect(state.error?.contains("declined") == true)
    }

    @Test func missingKeyMessage() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(),
                                    client: FakeClient([.failure(AnthropicError.missingKey)]))
        let state = await pipeline.run(makeState(env))
        #expect(state.error == "Add your Anthropic API key in Settings")
    }

    @Test func transcriptReusedWhenModelMatches() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        var stored = FakeTranscriber.speech
        stored.model = "fake-model"
        try JSONEncoder().encode(stored).write(to: env.folder.transcriptMetaURL.creatingParent())
        let transcriber = FakeTranscriber()
        let pipeline = makePipeline(env, transcriber: transcriber,
                                    client: FakeClient([FakeClient.notes(), FakeClient.verify()]))

        let state = await pipeline.run(makeState(env))

        #expect(state.stage == .done)
        #expect(await transcriber.calls == 0)
    }

    @Test func transcriptNotReusedForOtherModelOrForced() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        var stored = FakeTranscriber.speech
        stored.model = "older-model"
        try JSONEncoder().encode(stored).write(to: env.folder.transcriptMetaURL.creatingParent())

        let other = FakeTranscriber()
        _ = await makePipeline(env, transcriber: other, client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(makeState(env))
        #expect(await other.calls == 1)

        let forced = FakeTranscriber()
        var state = makeState(env)
        state.forceRetranscribe = true
        _ = await makePipeline(env, transcriber: forced, client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(state)
        #expect(await forced.calls == 1)
    }

    @Test func transcriptNotReusedWhenAudioOutsideFolder() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try JSONEncoder().encode(FakeTranscriber.speech).write(to: env.folder.transcriptMetaURL.creatingParent())
        let outside = env.root.appendingPathComponent("memo.m4a")
        try Data("memo".utf8).write(to: outside)
        let transcriber = FakeTranscriber()

        _ = await makePipeline(env, transcriber: transcriber,
                               client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(makeState(env, audio: [env.folder.audioURL, outside]))

        #expect(await transcriber.calls == 2)
    }

    @Test func transcriptNotReusedWhenFilesDiffer() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        // The stored transcript covers only audio.m4a; a second copied part now joins it.
        try JSONEncoder().encode(FakeTranscriber.speech).write(to: env.folder.transcriptMetaURL.creatingParent())
        let second = env.folder.url.appendingPathComponent("audio-2.m4a")
        try Data("part 2".utf8).write(to: second)
        let transcriber = FakeTranscriber()

        _ = await makePipeline(env, transcriber: transcriber,
                               client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(makeState(env, audio: [env.folder.audioURL, second]))

        #expect(await transcriber.calls == 2)
    }

    /// R38: one recording reuses only a transcript made from that same file.
    @Test func aLoneOtherRecordingDoesNotReuseTheTranscriptOfAudio() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        _ = await makePipeline(env, transcriber: FakeTranscriber(),
                               client: FakeClient([FakeClient.notes(), FakeClient.verify()])).run(makeState(env))
        let stored = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: env.folder.transcriptMetaURL))
        #expect(stored.audioFiles == ["audio.m4a"])
        let second = env.folder.url.appendingPathComponent("audio-2.m4a")
        try Data("part 2".utf8).write(to: second)

        let same = FakeTranscriber()
        _ = await makePipeline(env, transcriber: same, client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(makeState(env))
        let other = FakeTranscriber()
        _ = await makePipeline(env, transcriber: other, client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(makeState(env, audio: [second]))

        #expect(await same.calls == 0)
        #expect(await other.calls == 1)
    }

    /// A transcript.json from before file names were recorded fits only the Record flow's `audio.<ext>`.
    @Test func anOlderTranscriptWithoutFileNamesFitsOnlyAudio() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        var legacy = FakeTranscriber.speech
        legacy.model = "fake-model"
        legacy.audioFiles = nil
        try JSONEncoder().encode(legacy).write(to: env.folder.transcriptMetaURL.creatingParent())
        let second = env.folder.url.appendingPathComponent("audio-2.m4a")
        try Data("part 2".utf8).write(to: second)

        let other = FakeTranscriber()
        _ = await makePipeline(env, transcriber: other, client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(makeState(env, audio: [second]))
        #expect(await other.calls == 1)

        try JSONEncoder().encode(legacy).write(to: env.folder.transcriptMetaURL)
        let record = FakeTranscriber()
        _ = await makePipeline(env, transcriber: record, client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
            .run(makeState(env))
        #expect(await record.calls == 0)
    }

    @Test func partsAreOffsetByDurationAndPausesApplied() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let second = env.folder.url.appendingPathComponent("audio-2.m4a")
        try Data("part 2".utf8).write(to: second)
        var state = makeState(env, audio: [env.folder.audioURL, second])
        state.markers = [.pause(at: 30, duration: 120)]
        let pipeline = Pipeline(
            folder: env.folder, transcriber: FakeTranscriber(),
            client: FakeClient([FakeClient.notes(), FakeClient.verify()]), styles: env.styles, ledger: env.ledger,
            now: { PipelineTests.now }, duration: { url in url.lastPathComponent == "audio.m4a" ? 2832 : 60 })

        _ = await pipeline.run(state)

        let md = try String(contentsOf: env.folder.transcriptURL, encoding: .utf8)
        #expect(md.contains("— Part 2: audio-2.m4a starts at [00:47:12] —"))
        #expect(md.contains("— paused at [00:00:30] for 2 min 0 s —"))
        let meta = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: env.folder.transcriptMetaURL))
        #expect(meta.markers.filter { if case .pause = $0 { true } else { false } }.count == 1)
    }

    @Test func placeholderTitleRenamesFolderWithoutSlides() async throws {
        let env = try makeEnv(title: "Lecture")
        defer { env.cleanup() }
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(),
                                    client: FakeClient([FakeClient.notes(), FakeClient.verify()]))

        let state = await pipeline.run(makeState(env, placeholder: true))

        #expect(state.stage == .done)
        #expect(!state.titleIsPlaceholder)
        let folder = await pipeline.folder
        #expect(folder.url.lastPathComponent == "2026-10-23 Linear Algebra")
        #expect(FileManager.default.fileExists(atPath: folder.notesURL.path))
        #expect(state.audio == [folder.audioURL])
        let saved = try JSONDecoder().decode(PipelineState.self, from: Data(contentsOf: folder.stateURL))
        #expect(saved.stage == .done)
        #expect(saved.audio == [folder.audioURL])
    }

    @Test func noRenameWhenTitleIsNotPlaceholder() async throws {
        let env = try makeEnv(title: "Week 3")
        defer { env.cleanup() }
        let pipeline = makePipeline(env, transcriber: FakeTranscriber(),
                                    client: FakeClient([FakeClient.notes(), FakeClient.verify()]))
        _ = await pipeline.run(makeState(env, placeholder: false))
        #expect(await pipeline.folder.url.lastPathComponent == "2026-10-23 Week 3")
    }
}

extension URL {
    /// Creates this file URL's parent directory and returns the URL.
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
