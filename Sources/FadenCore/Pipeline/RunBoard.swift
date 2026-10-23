import Foundation

/// The pipeline runs the status row shows, newest first. The folders of runs that aren't done are kept
/// (in UserDefaults, by the app) so a run cut short by a quit or crash still offers Retry after a relaunch.
public struct RunBoard: Equatable, Sendable {
    public struct Run: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var folder: LectureFolder
        public var stage: Stage
        public var error: String?
        public var isRunning: Bool
        /// A failed run has a stage Retry resumes at; without one only dismissing (or Process again) is left.
        public var canResume: Bool
        /// The notes file a finished run saved.
        public var notes: URL?
        /// The finished run's notes file has been deleted since.
        public var notesDeleted: Bool

        public init(id: UUID, folder: LectureFolder, stage: Stage, error: String?, isRunning: Bool,
                    canResume: Bool = true, notes: URL? = nil, notesDeleted: Bool = false) {
            self.id = id
            self.folder = folder
            self.stage = stage
            self.error = error
            self.isRunning = isRunning
            self.canResume = canResume
            self.notes = notes
            self.notesDeleted = notesDeleted
        }
    }

    /// Shown for a restored run whose state was saved mid-stage (Faden quit or crashed while processing).
    public static let interruptedMessage = "Processing was interrupted. Retry continues where it stopped."
    /// The most runs the status row lists before "+N more".
    public static let visibleLimit = 3

    /// Newest first.
    public private(set) var runs: [Run]

    public init(runs: [Run] = []) {
        self.runs = runs
    }

    public var latest: Run? { runs.first }
    public var isRunning: Bool { runs.contains(where: \.isRunning) }

    /// The newest run, plus older ones still running or failed: a finished older run drops out of view.
    /// Every run not done is listed, so none is kept across launches yet unreachable.
    public var visible: [Run] {
        runs.enumerated()
            .filter { $0.offset == 0 || $0.element.isRunning || $0.element.stage != .done }
            .map(\.element)
    }

    /// What the status row lists: all of `visible` when expanded, otherwise its first `visibleLimit` runs and
    /// how many more a "+N more" row reveals.
    public func shown(expanded: Bool) -> (runs: [Run], more: Int) {
        let all = visible
        guard !expanded, all.count > Self.visibleLimit else { return (all, 0) }
        return (Array(all.prefix(Self.visibleLimit)), all.count - Self.visibleLimit)
    }

    /// The folders of runs that aren't done, newest first, for saving across launches.
    public var unfinishedPaths: [String] {
        runs.filter { $0.stage != .done }.map(\.folder.url.path)
    }

    /// Adds a run at the top. An idle entry for the same folder (e.g. the failure being retried) is replaced.
    public mutating func start(_ id: UUID, folder: LectureFolder, stage: Stage) {
        runs.removeAll { !$0.isRunning && Self.sameFolder($0.folder, folder) }
        runs.insert(Run(id: id, folder: folder, stage: stage, error: nil, isRunning: true), at: 0)
        dropHiddenRuns()
    }

    /// Lists `folder` at the top as ready to process (recorded, not processed). An idle entry for it, or for
    /// `previous` (its name before a rename), is replaced. `error` says why Process couldn't start.
    public mutating func ready(_ folder: LectureFolder, replacing previous: LectureFolder? = nil, error: String? = nil) {
        let replaced = [folder] + (previous.map { [$0] } ?? [])
        runs.removeAll { run in !run.isRunning && replaced.contains { Self.sameFolder(run.folder, $0) } }
        runs.insert(Run(id: UUID(), folder: folder, stage: .ready, error: error, isRunning: false, canResume: false), at: 0)
        dropHiddenRuns()
    }

    /// Progress from the run's pipeline.
    public mutating func update(_ id: UUID, stage: Stage) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].stage = stage
        runs[i].error = nil
    }

    /// The run's outcome; `folder` may differ from the start when saving renamed it. `canResume` says
    /// whether a failure has a stage to retry from; `notes` is the file a finished run saved.
    public mutating func finish(_ id: UUID, folder: LectureFolder, stage: Stage, error: String?,
                                canResume: Bool = true, notes: URL? = nil) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].folder = folder
        runs[i].stage = stage
        runs[i].error = error
        runs[i].isRunning = false
        runs[i].canResume = canResume
        runs[i].notes = notes
        runs[i].notesDeleted = false
        dropHiddenRuns()
    }

    /// Forgets a failed or ready run (the user dismissed it). Files are never touched; a running run stays.
    public mutating func dismiss(_ id: UUID) {
        runs.removeAll { $0.id == id && !$0.isRunning }
    }

    /// Re-checks the idle runs against the disk: a run whose lecture folder is gone is forgotten, and a
    /// finished run whose notes file is gone is marked `notesDeleted`. Running runs are left alone.
    public mutating func noticeDeletedFiles(exists: (URL) -> Bool) {
        runs.removeAll { !$0.isRunning && !exists($0.folder.url) }
        for i in runs.indices where !runs[i].isRunning {
            if let notes = runs[i].notes, !exists(notes) {
                runs[i].notes = nil
                runs[i].notesDeleted = true
            }
        }
    }

    /// Rebuilds the board at launch from saved folder paths. Each folder whose `.faden/state.json` is
    /// readable and not done shows as a failed run that Retry resumes, or, when it was never processed, as
    /// ready to process; deleted or finished folders are dropped.
    public static func restored(paths: [String]) -> RunBoard {
        var seen = Set<String>()
        let runs = paths.compactMap { path -> Run? in
            let folder = LectureFolder(url: URL(fileURLWithPath: path, isDirectory: true))
            guard seen.insert(folder.url.standardizedFileURL.path).inserted,
                  let state = PipelineState.saved(in: folder), state.stage != .done
            else { return nil }
            if state.stage == .ready {
                return Run(id: UUID(), folder: folder, stage: .ready, error: nil, isRunning: false, canResume: false)
            }
            let error = state.stage == .failed ? state.error : interruptedMessage
            return Run(id: UUID(), folder: folder, stage: .failed, error: error, isRunning: false,
                       canResume: state.resumeStage != nil)
        }
        return RunBoard(runs: runs)
    }

    /// Finished runs that are no longer visible are forgotten.
    private mutating func dropHiddenRuns() {
        runs = runs.enumerated()
            .filter { $0.offset == 0 || $0.element.isRunning || $0.element.stage != .done }
            .map(\.element)
    }

    private static func sameFolder(_ a: LectureFolder, _ b: LectureFolder) -> Bool {
        a.url.standardizedFileURL.path == b.url.standardizedFileURL.path
    }
}
