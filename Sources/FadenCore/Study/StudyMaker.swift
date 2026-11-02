import Foundation
import os

/// Makes flashcards and study guides: sends the request, records the call in the cost ledger and writes the file.
public struct StudyMaker: Sendable {
    let client: MessageSending
    let ledger: CostLedger
    let now: @Sendable () -> Date
    let model: String

    private static let log = Logger(subsystem: FadenCore.identifier, category: "Study")

    public init(client: MessageSending, ledger: CostLedger, model: String = NotesPrompt.model,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.ledger = ledger
        self.model = model
        self.now = now
    }

    /// Writes `flashcards.md` into `lecture` from `notes` (replacing an earlier one) and returns its URL.
    /// `examples` are past exam questions whose style the cards follow.
    public func flashcards(for lecture: LectureFolder, notes: URL, title: String, examples: String? = nil)
        async throws -> URL {
        let text = try String(contentsOf: notes, encoding: .utf8)
        let result = try await client.send(try Flashcards.request(notes: text, examples: examples, model: model))
        let call = record(result, step: .flashcards, name: lecture.url.lastPathComponent)
        let cards = try Flashcards.parse(result.text)
        Self.log.info("\(cards.count) flashcards for \(lecture.url.lastPathComponent, privacy: .public)")
        let target = lecture.url.appendingPathComponent(Flashcards.fileName)
        let markdown = Flashcards.markdown(cards, title: title, notesFile: notes.lastPathComponent, call: call, date: now())
        try Data(markdown.utf8).write(to: target, options: .atomic)
        return target
    }

    /// Writes a new `Study guide <date>.md` into `course` from `lectures` and returns its URL.
    public func studyGuide(for course: URL, lectures: [StudyGuide.Lecture]) async throws -> URL {
        let result = try await client.send(try StudyGuide.request(lectures, model: model))
        if result.stopReason == "max_tokens" { throw AnthropicError.truncated }
        let call = record(result, step: .studyGuide, name: course.lastPathComponent)
        let target = StudyGuide.fileURL(in: course, date: now())
        let markdown = StudyGuide.markdown(result.text, lectures: lectures, call: call, date: now())
        try Data(markdown.utf8).write(to: target, options: .withoutOverwriting)
        Self.log.info("Study guide for \(course.lastPathComponent, privacy: .public) from \(lectures.count) lectures")
        return target
    }

    /// Cost tracking is best effort: a ledger that can't be written must not lose a paid result.
    private func record(_ result: MessageResult, step: CostRecord.Step, name: String) -> PaidCall {
        let call = PaidCall(model: result.model, usage: result.usage, subscription: result.subscription,
                            subscriptionBefore: result.subscriptionBefore)
        do {
            try ledger.append(CostRecord(date: now(), lecture: name, step: step, call: call))
        } catch {
            Self.log.error("Writing the cost ledger failed: \(error, privacy: .public)")
        }
        return call
    }
}
