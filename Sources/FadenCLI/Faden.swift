import ArgumentParser
import FadenCore
import FadenTranscription
import Foundation

@main
struct Faden: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "faden",
        abstract: "Turn lecture recordings, slides and your notes into labelled study notes.",
        discussion: """
            Transcription runs on this Mac. The notes and check calls go to the Anthropic API with \
            ANTHROPIC_API_KEY (or the key the Faden app stored in the Keychain), or with --subscription \
            through the local claude CLI on your Claude subscription.
            """,
        subcommands: [ProcessCommand.self, RetryCommand.self, StylesCommand.self, FlashcardsCommand.self,
                      StudyGuideCommand.self])
}

/// Options shared by the commands that run the pipeline.
struct RunOptions: ParsableArguments {
    @Option(help: "The speech model: fast (small) or accurate (large, a big first download).")
    var model: ModelOption = .fast

    @Option(help: ArgumentHelp("The model that writes the notes: opus, sonnet (5.5) or sonnet-5.",
                               discussion: "`faden retry` keeps the models the run was started with.",
                               valueName: "model"))
    var notesModel: NotesModelOption = .opus

    @Option(help: ArgumentHelp("The model that checks the notes against the sources: haiku, sonnet (5.5) or opus.",
                               valueName: "model"))
    var checkModel: CheckModelOption = .haiku

    @Flag(help: "Send the calls through the local claude CLI on your Claude subscription instead of an API key.")
    var subscription = false

    @Option(help: ArgumentHelp("A folder of style files to use instead of the installed ones.",
                               discussion: "Point it at Sources/FadenCore/Resources/styles to try style changes.",
                               valueName: "dir"))
    var stylesDir: String?

    var styles: StyleStore {
        get throws {
            if let stylesDir { return StyleStore(dir: URL(filePath: stylesDir, directoryHint: .isDirectory)) }
            let store = StyleStore()
            try store.installDefaultsIfMissing()
            return store
        }
    }
}

/// Options of the commands that make something from existing notes.
struct StudyOptions: ParsableArguments {
    @Option(help: ArgumentHelp("The model: opus, sonnet (5.5) or sonnet-5.", valueName: "model"))
    var model: NotesModelOption = .opus

    @Flag(help: "Send the call through the local claude CLI on your Claude subscription instead of an API key.")
    var subscription = false

    func maker() throws -> StudyMaker {
        let client = try ClientChoice.make(subscription: subscription, environment: ProcessInfo.processInfo.environment)
        return StudyMaker(client: client, ledger: CostLedger(), model: model.id)
    }
}

enum ModelOption: String, CaseIterable, ExpressibleByArgument {
    case fast, accurate

    var model: TranscriptionModel {
        switch self {
        case .fast: .fast
        case .accurate: .accurate
        }
    }
}

enum NotesModelOption: String, CaseIterable, ExpressibleByArgument {
    case opus, sonnet, sonnet5 = "sonnet-5"

    var id: String {
        switch self {
        case .opus: NotesPrompt.model
        case .sonnet: "claude-sonnet-5-5"
        case .sonnet5: "claude-sonnet-5"
        }
    }
}

enum CheckModelOption: String, CaseIterable, ExpressibleByArgument {
    case haiku, sonnet, opus

    var id: String {
        switch self {
        case .haiku: Verifier.model
        case .sonnet: "claude-sonnet-5-5"
        case .opus: NotesPrompt.model
        }
    }
}

extension Faden {
    struct ProcessCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "process",
            abstract: "Transcribe recordings and write notes into a new lecture folder.",
            discussion: """
                Creates "<date> <title>" in the output folder (titled after the first slide PDF), copies the \
                audio in and saves notes.md, transcript.md and the run's state there. Audio already in a \
                lecture folder inside the output folder is processed in place, and a new notes file is \
                added next to the old ones.
                """)

        @Argument(help: "Audio files in playback order.")
        var audio: [String]

        @Option(name: .shortAndLong, help: "The course folder the lecture folder goes into.")
        var out: String

        @Option(parsing: .upToNextOption, help: "Slide PDFs, in order.")
        var slides: [String] = []

        @Option(help: "Your own notes (Markdown, text or PDF).")
        var notes: String?

        @Option(help: "The note style: its id or letter, e.g. C or C-red-line. See `faden styles`.")
        var style = "C"

        @Flag(help: "Leave out the model's own 💡 additions.")
        var noAdditions = false

        @Option(help: "The lecture's language as an ISO code (de, en); detected when left out.")
        var language: String?

        @Flag(help: "Transcribe again even if the lecture folder has a transcript.")
        var retranscribe = false

        @OptionGroup var options: RunOptions

        func run() async throws {
            let styles = try options.styles
            let styleID = try StyleChoice.id(for: style, among: styles.all().map(\.id))
            let request = ReprocessRequest(
                recordings: audio.map(Self.fileURL), courseFolder: Self.fileURL(out).standardizedFileURL,
                slides: slides.map(Self.fileURL), userNotes: notes.map(Self.fileURL), styleID: styleID,
                allowAdditions: !noAdditions, language: language, forceRetranscribe: retranscribe)
            let missing = RecordingList.missing(request.recordings + request.slides + (request.userNotes.map { [$0] } ?? []))
            guard missing.isEmpty else {
                throw ValidationError("Not found: \(missing.map(\.path).joined(separator: ", "))")
            }
            let plan = try ReprocessPlanner.plan(request, now: Date())
            let pipeline = try PipelineRun.make(folder: plan.folder, options: options, styles: styles)
            try await PipelineRun.follow(pipeline) { await pipeline.run(plan.state) }
        }

        static func fileURL(_ path: String) -> URL {
            URL(filePath: (path as NSString).expandingTildeInPath)
        }
    }

    struct RetryCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "retry",
            abstract: "Continue a failed or interrupted run from the stage where it stopped.",
            discussion: "Paid stages that finished are not paid for again.")

        @Argument(help: "The lecture folder.")
        var folder: String

        @OptionGroup var options: RunOptions

        func run() async throws {
            let lecture = LectureFolder(url: ProcessCommand.fileURL(folder).standardizedFileURL)
            guard let state = PipelineState.saved(in: lecture) else {
                throw ValidationError("\(lecture.url.path) has no saved run")
            }
            guard state.resumeStage != nil else {
                throw ValidationError("Nothing to retry: the run is \(state.stage.rawValue)")
            }
            var runOptions = options
            // Keep the speech model the transcript was made with, so it is reused.
            if let model = TranscriptionModel(variant: state.transcriptionModel) {
                runOptions.model = model == .accurate ? .accurate : .fast
            }
            let pipeline = try PipelineRun.make(folder: lecture, options: runOptions, styles: try options.styles)
            try await PipelineRun.follow(pipeline) { await pipeline.retry() }
        }
    }

    struct FlashcardsCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "flashcards",
            abstract: "Make exam-style flashcards from a lecture's notes.",
            discussion: """
                One call over the notes (not the transcript) writes flashcards.md into the lecture folder; \
                --csv also writes flashcards.csv for Anki's text import.
                """)

        @Argument(help: "The lecture folder.")
        var folder: String

        @Option(help: "The notes file to use; the newest notes.md by default.")
        var notes: String?

        @Option(help: "A file of past exam questions whose style the cards should follow.")
        var examples: String?

        @Flag(help: "Also write flashcards.csv (Front, Back, Tags) for Anki.")
        var csv = false

        @OptionGroup var options: StudyOptions

        func run() async throws {
            let url = ProcessCommand.fileURL(folder).standardizedFileURL
            let lecture = LectureFolder(url: url)
            guard let entry = Library.lecture(at: url, course: url.deletingLastPathComponent()) else {
                throw ValidationError("\(url.path) isn't a lecture folder")
            }
            guard let notesFile = notes.map(ProcessCommand.fileURL) ?? entry.notes.first else {
                throw ValidationError("\(url.lastPathComponent) has no notes yet")
            }
            let examplesText = try examples.map { try String(contentsOf: ProcessCommand.fileURL($0), encoding: .utf8) }
            PipelineRun.printErr("Making flashcards from \(notesFile.lastPathComponent)…")
            let file = try await options.maker().flashcards(for: lecture, notes: notesFile, title: entry.title,
                                                           examples: examplesText)
            if csv {
                let cards = Flashcards.read(try String(contentsOf: file, encoding: .utf8))
                let target = url.appendingPathComponent("flashcards.csv")
                try Flashcards.csv(cards, tags: [entry.course.lastPathComponent, entry.title])
                    .write(to: target, atomically: true, encoding: .utf8)
                print(target.path)
            }
            print(file.path)
        }
    }

    struct StudyGuideCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "study-guide",
            abstract: "Make a study guide for a course from its lectures' notes.",
            discussion: """
                One call over the newest notes of the course's lectures (in date order, subfolders included) \
                writes "Study guide <date>.md" into the course folder.
                """)

        @Argument(help: "The course folder.")
        var course: String

        @Option(parsing: .upToNextOption, help: "Only these lecture folders (in the course); all with notes by default.")
        var lectures: [String] = []

        @OptionGroup var options: StudyOptions

        func run() async throws {
            let url = ProcessCommand.fileURL(course).standardizedFileURL
            var chosen = Library.tree(at: url).allLectures.filter { !$0.notes.isEmpty }
            if !lectures.isEmpty {
                let wanted = Set(lectures.map { ProcessCommand.fileURL($0).standardizedFileURL.path })
                chosen = chosen.filter { wanted.contains($0.folder.url.standardizedFileURL.path) }
            }
            chosen.sort { a, b in
                let (da, db) = (a.date ?? .distantPast, b.date ?? .distantPast)
                return da != db ? da < db : a.title < b.title
            }
            guard !chosen.isEmpty else { throw ValidationError("No lectures with notes in \(url.path)") }
            let inputs = try chosen.map { lecture in
                StudyGuide.Lecture(title: lecture.title, path: Self.relative(lecture.folder.url, to: url),
                                   notes: try String(contentsOf: lecture.notes[0], encoding: .utf8))
            }
            PipelineRun.printErr("Making a study guide from \(inputs.count) lectures…")
            print(try await options.maker().studyGuide(for: url, lectures: inputs).path)
        }

        static func relative(_ folder: URL, to course: URL) -> String {
            let base = course.standardizedFileURL.path + "/"
            let path = folder.standardizedFileURL.path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : folder.lastPathComponent
        }
    }

    struct StylesCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "styles", abstract: "List the note styles.")

        @Option(help: "A folder of style files to use instead of the installed ones.")
        var stylesDir: String?

        func run() throws {
            var options = try RunOptions.parse([])
            options.stylesDir = stylesDir
            let styles = try options.styles
            print("Styles in \(styles.dir.path):")
            for style in try styles.all() {
                let fallback = style.fallbackID.map { ", without slides: \($0)" } ?? ""
                print("  \(style.id)  \(style.name)\(style.requiresSlides ? " (needs slides\(fallback))" : "")")
            }
        }
    }
}

/// Builds a pipeline like the app does and reports its run on the terminal.
enum PipelineRun {
    static func make(folder: LectureFolder, options: RunOptions, styles: StyleStore) throws -> Pipeline {
        let client = try ClientChoice.make(subscription: options.subscription, environment: ProcessInfo.processInfo.environment)
        return Pipeline(folder: folder, transcriber: WhisperKitTranscriber(model: options.model.model), client: client,
                        styles: styles, ledger: CostLedger(), now: { Date() }, notesModel: options.notesModel.id,
                        checkModel: options.checkModel.id)
    }

    /// Prints each stage as it starts, runs `work`, then prints where the notes went or throws with the error.
    static func follow(_ pipeline: Pipeline, _ work: @escaping @Sendable () async -> PipelineState) async throws {
        let watcher = Task {
            for await stage in pipeline.progress {
                if let line = line(for: stage) { printErr(line) }
            }
        }
        let state = await work()
        watcher.cancel()
        let folder = await pipeline.folder
        guard state.stage == .done else {
            printErr("Failed\(state.failedStage.map { " while \(describe($0))" } ?? ""): \(state.error ?? "unknown error")")
            if state.resumeStage != nil { printErr("Run `faden retry \"\(folder.url.path)\"` to continue.") }
            throw ExitCode.failure
        }
        let calls = [state.notesCall, state.verifyCall].compactMap(\.self)
        let usd = calls.compactMap(\.usd).reduce(0, +)
        printErr(String(format: "Done. Cost: $%.2f", usd) + (calls.contains { $0.subscription != nil } ? " (subscription)" : ""))
        print(StopFlow.latestNotes(in: folder)?.path ?? folder.url.path)
    }

    static func line(for stage: Stage) -> String? {
        switch stage {
        case .transcribing: "Transcribing (the first run downloads the speech model)…"
        case .writingNotes, .verifying, .saving: describe(stage).prefix(1).uppercased() + describe(stage).dropFirst() + "…"
        case .ready, .done, .failed: nil
        }
    }

    static func describe(_ stage: Stage) -> String {
        switch stage {
        case .transcribing: "transcribing"
        case .writingNotes: "writing notes"
        case .verifying: "checking the notes"
        case .saving: "saving"
        case .ready: "ready"
        case .done: "done"
        case .failed: "failed"
        }
    }

    static func printErr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
