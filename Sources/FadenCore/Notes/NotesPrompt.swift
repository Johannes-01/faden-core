import Foundation

public struct NotesInputs: Sendable {
    public var transcript: Transcript
    public var slides: [URL]
    public var userNotes: URL?
    public var style: NoteStyle
    public var allowAdditions: Bool
    /// A language code such as `de` or `en`; nil means the lecture's own language.
    public var languageOverride: String?

    public init(transcript: Transcript, slides: [URL], userNotes: URL?, style: NoteStyle,
                allowAdditions: Bool, languageOverride: String?) {
        self.transcript = transcript
        self.slides = slides
        self.userNotes = userNotes
        self.style = style
        self.allowAdditions = allowAdditions
        self.languageOverride = languageOverride
    }
}

public enum NotesPromptError: Error, Equatable {
    case missingResource(String)
}

/// Builds the Opus request that writes the lecture notes.
public enum NotesPrompt {
    /// The model the notes call asks for.
    public static let model = "claude-opus-5-5"

    public static func request(_ i: NotesInputs) throws -> MessageRequest {
        var system = try baseSystemPrompt() + "\n\n## Style\n" + i.style.prompt
        if !i.allowAdditions {
            system += "\n\n" + noAdditionsRule
        }
        if let code = i.languageOverride, !code.isEmpty {
            system += "\n\n" + languageInstruction(code)
        }

        // Stable, cacheable PDFs first; the transcript changes with every recording. Notes that are a PDF
        // (e.g. handwritten) go like slides: page text plus images of the figures.
        let notesPDF = i.userNotes.flatMap { SlideInput.isPDF($0) ? $0 : nil }
        var content = try SlideInput.blocks(for: i.slides, notes: notesPDF)
        if let url = i.userNotes, notesPDF == nil, let notes = try readNotes(url) {
            content.append(.text("My own notes from the lecture (label content from here ✍️):\n" + notes, cache: false))
        }
        content.append(.text(i.transcript.markdown(), cache: false))

        return MessageRequest(
            model: model,
            maxTokens: 64000,
            stream: true,
            system: [.text(system, cache: false)],
            messages: [Message(content: content)],
            outputConfig: OutputConfig(effort: "high"),
            fallbacks: "default",
            betaHeaders: ["server-side-fallback-2026-07-01"])
    }

    /// Appended when additions are off. It comes after the style, so it overrides style rules that ask for 💡.
    static let noAdditionsRule = "Do not add explanations, examples or context of your own; omit 💡 entirely. "
        + "This overrides any instruction above that asks for 💡 content, such as likely exam questions "
        + "or your own examples; leave those out, because the student asked for notes from the sources only."

    static func baseSystemPrompt() throws -> String {
        guard let url = FadenCore.resources.url(forResource: "notes-system", withExtension: "md", subdirectory: "prompts") else {
            throw NotesPromptError.missingResource("prompts/notes-system.md")
        }
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func languageInstruction(_ code: String) -> String {
        switch code.lowercased() {
        case "de": "Write the notes in German."
        case "en": "Write the notes in English."
        default: "Write the notes in the language with code \(code)."
        }
    }

    /// The user's notes as text (UTF-8, else Latin-1), or nil when the file is blank.
    private static func readNotes(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
