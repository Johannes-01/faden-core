import Foundation
import Testing
@testable import FadenCore

/// Records what it was asked and answers with a reservation, or refuses at a step.
actor RecordingGate: PaidCallGate {
    struct Refusal: LocalizedError {
        var errorDescription: String? { "Out of lectures" }
    }

    private(set) var steps: [CostRecord.Step] = []
    private(set) var reservations: [String?] = []
    private(set) var states: [PipelineState?] = []
    private let refusing: CostRecord.Step?

    init(refusing: CostRecord.Step? = nil) { self.refusing = refusing }

    func admit(_ step: CostRecord.Step, state: PipelineState?, reservation: String?) async throws -> String {
        steps.append(step)
        reservations.append(reservation)
        states.append(state)
        if step == refusing { throw Refusal() }
        return reservation ?? "r1"
    }
}

/// A client that keeps the reservation tag of each request.
actor TagRecordingClient: MessageSending {
    private var script: [Result<MessageResult, Error>]
    private(set) var calls = 0
    private(set) var reservationIDs: [String?] = []

    init(_ script: [Result<MessageResult, Error>]) { self.script = script }

    func send(_ r: MessageRequest) async throws -> MessageResult {
        calls += 1
        reservationIDs.append(r.tag?.reservationID)
        guard !script.isEmpty else { throw AnthropicError.network("no scripted result") }
        return try script.removeFirst().get()
    }
}

@Suite struct PaidCallGateTests {
    private struct Env {
        let root: URL
        let folder: LectureFolder
        let styles: StyleStore
        let ledger: CostLedger
    }

    private static let now = Date(timeIntervalSince1970: 1_792_756_800)

    private func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("faden-gate-\(UUID().uuidString)")
        let folder = try LectureFolder.create(in: root.appendingPathComponent("Course"), date: Self.now, title: "Lecture")
        try Data("fake audio".utf8).write(to: folder.audioURL)
        let styles = StyleStore(dir: root.appendingPathComponent("styles"))
        try styles.installDefaultsIfMissing()
        return Env(root: root, folder: folder, styles: styles, ledger: CostLedger(file: root.appendingPathComponent("costs.jsonl")))
    }

    private func pipeline(_ env: Env, client: MessageSending, gate: PaidCallGate?) -> Pipeline {
        Pipeline(folder: env.folder, transcriber: FakeTranscriber(), client: client, styles: env.styles, ledger: env.ledger,
                 now: { Self.now }, duration: { _ in 60 }, gate: gate)
    }

    private func state(_ env: Env) -> PipelineState {
        PipelineState(audio: [env.folder.audioURL], styleID: "C-red-line", allowAdditions: true)
    }

    @Test func gateRunsBeforeEachPaidCallAndTagsTheRequest() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let gate = RecordingGate()
        let client = TagRecordingClient([FakeClient.notes(), FakeClient.verify()])

        let end = await pipeline(env, client: client, gate: gate).run(state(env))

        #expect(end.stage == .done)
        #expect(await gate.steps == [.notes, .verify])
        #expect(await client.reservationIDs == ["r1", "r1"])
        #expect(end.reservationID == "r1")
    }

    @Test func reservationIsSavedBeforeTheNotesCall() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let client = TagRecordingClient([.failure(AnthropicError.network("down"))])

        let end = await pipeline(env, client: client, gate: RecordingGate()).run(state(env))

        #expect(end.stage == .failed)
        #expect(PipelineState.saved(in: env.folder)?.reservationID == "r1")
    }

    @Test func retryReusesReservation() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let gate = RecordingGate()
        let first = await pipeline(env, client: TagRecordingClient([.failure(AnthropicError.network("down"))]), gate: gate)
            .run(state(env))
        #expect(first.failedStage == .writingNotes)

        let client = TagRecordingClient([FakeClient.notes(), FakeClient.verify()])
        let retried = await pipeline(env, client: client, gate: gate).retry()

        #expect(retried.stage == .done)
        #expect(await gate.reservations.first == .some(nil))
        #expect(await gate.reservations.dropFirst().first == .some("r1"))
        #expect(await client.reservationIDs == ["r1", "r1"])
    }

    @Test func gateRefusalBeforeNotesSendsNothing() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let client = TagRecordingClient([FakeClient.notes()])

        let end = await pipeline(env, client: client, gate: RecordingGate(refusing: .notes)).run(state(env))

        #expect(await client.calls == 0)
        #expect(end.stage == .failed)
        #expect(end.failedStage == .writingNotes)
        #expect(end.error == "Out of lectures")
    }

    @Test func gateRefusalAtVerifyFailsRun() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let client = TagRecordingClient([FakeClient.notes(), FakeClient.verify()])

        let end = await pipeline(env, client: client, gate: RecordingGate(refusing: .verify)).run(state(env))

        #expect(await client.calls == 1)
        #expect(end.stage == .failed)
        #expect(end.failedStage == .verifying)
        #expect(end.error == "Out of lectures")
        #expect(end.verificationSkipped == nil)
    }

    @Test func noGateNoChange() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let client = TagRecordingClient([FakeClient.notes(), FakeClient.verify()])

        let end = await pipeline(env, client: client, gate: nil).run(state(env))

        #expect(end.stage == .done)
        #expect(end.reservationID == nil)
        #expect(await client.reservationIDs == [nil, nil])
        let json = try String(contentsOf: env.folder.stateURL, encoding: .utf8)
        #expect(!json.contains("reservationID"))
    }

    @Test func studyMakerAdmitsBeforeFlashcards() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let notes = env.folder.url.appendingPathComponent("notes.md")
        try "# Raft\n\n- 🗣 Leaders.\n".write(to: notes, atomically: true, encoding: .utf8)
        let reply = MessageResult(text: #"{"cards":[{"question":"Q?","answer":"A.","source":"🗣 [00:23:14]"}]}"#,
                                  model: "claude-sonnet-5-5", stopReason: "end_turn", usage: Usage())
        let client = TagRecordingClient([.success(reply)])
        let gate = RecordingGate()
        let maker = StudyMaker(client: client, ledger: env.ledger, now: { Self.now }, gate: gate)

        _ = try await maker.flashcards(for: env.folder, notes: notes, title: "Raft")
        #expect(await gate.steps == [.flashcards])
        #expect(await gate.states.count == 1)
        #expect(await gate.states[0] == nil)
        #expect(await client.reservationIDs == ["r1"])

        let refusing = StudyMaker(client: client, ledger: env.ledger, now: { Self.now }, gate: RecordingGate(refusing: .flashcards))
        await #expect(throws: RecordingGate.Refusal.self) {
            try await refusing.flashcards(for: env.folder, notes: notes, title: "Raft")
        }
        #expect(await client.calls == 1)
    }
}
