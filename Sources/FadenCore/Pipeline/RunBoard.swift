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

        public init(id: UUID, folder: LectureFolder, stage: Stage, error: String?, isRunning: Bool) {
            self.id = id
            self.folder = folder
            self.stage = stage
            self.error = error
            self.isRunning = isRunning
        }
    }

    /// Shown for a restored run whose state was saved mid-stage (Faden quit or crashed while processing).
    public static let interruptedMessage = "Processing was interrupted. Retry continues where it stopped."
    /// The most runs the status row lists.
    public static let visibleLimit = 3

    /// Newest first.
    public private(set) var runs: [Run]

    public init(runs: [Run] = []) {
        self.runs = runs
    }

    public var latest: Run? { runs.first }
    public var isRunning: Bool { runs.contains(where: \.isRunning) }

    /// The newest run, plus older ones still running or failed: a finished older run drops out of view.
    public var visible: [Run] {
        Array(runs.enumerated()
            .filter { $0.offset == 0 || $0.element.isRunning || $0.element.stage != .done }
            .map(\.element)
            .prefix(Self.visibleLimit))
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

    /// Progress from the run's pipeline.
    public mutating func update(_ id: UUID, stage: Stage) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].stage = stage
        runs[i].error = nil
    }

    /// The run's outcome; `folder` may differ from the start when saving renamed it.
    public mutating func finish(_ id: UUID, folder: LectureFolder, stage: Stage, error: String?) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].folder = folder
        runs[i].stage = stage
        runs[i].error = error
        runs[i].isRunning = false
        dropHiddenRuns()
    }

    /// Rebuilds the board at launch from saved folder paths. Each folder whose `.faden/state.json` is
    /// readable and not done shows as a failed run that Retry resumes; deleted or finished folders are
    /// dropped.
    public static func restored(paths: [String]) -> RunBoard {
        var seen = Set<String>()
        let runs = paths.compactMap { path -> Run? in
            let folder = LectureFolder(url: URL(fileURLWithPath: path, isDirectory: true))
            guard seen.insert(folder.url.standardizedFileURL.path).inserted,
                  let state = PipelineState.saved(in: folder), state.stage != .done
            else { return nil }
            let error = state.stage == .failed ? state.error : interruptedMessage
            return Run(id: UUID(), folder: folder, stage: .failed, error: error, isRunning: false)
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
