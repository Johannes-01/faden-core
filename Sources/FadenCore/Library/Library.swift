import Foundation

/// Where a lecture in the library stands, read from its folder (not from the runs of this session).
public enum LibraryStatus: Equatable, Sendable {
    /// Recorded, not processed yet.
    case ready
    /// `state.json` says a stage was running, but no run here is working on it: Faden quit or crashed mid-run,
    /// or another device is processing it. Retry continues at that stage.
    case interrupted(Stage)
    /// `stage` is where it failed, nil if the state doesn't say.
    case failed(stage: Stage?, error: String?)
    case done
    /// Processed, but no `notes*.md` is left in the folder.
    case notesMissing
    /// No readable state and no notes, e.g. while `state.json` is still in iCloud.
    case unknown
}

/// One lecture folder in a course folder, as the library lists it.
public struct LibraryLecture: Equatable, Sendable, Identifiable {
    public var id: String { folder.url.standardizedFileURL.path }
    public var folder: LectureFolder
    /// The course folder it sits in.
    public var course: URL
    /// The folder name without its date.
    public var title: String
    /// From the folder name's `yyyy-MM-dd`; nil when it doesn't start with one.
    public var date: Date?
    /// The title came from no slides ("Lecture") and saving will replace it.
    public var titleIsPlaceholder: Bool
    public var status: LibraryStatus
    /// `notes.md` and its re-runs, newest first.
    public var notes: [URL]
    public var transcript: URL?
    /// The slides the lecture was (or will be) processed with, from its state.
    public var slides: [URL]
    /// The recorded parts in playback order.
    public var audio: [URL]
    /// Recorded audio in seconds, from the transcript; nil before transcribing.
    public var length: TimeInterval?
    /// From the newest notes' header: `$0.82`, or `Subscription` for a run on the Claude subscription.
    public var cost: String?
    /// The newest notes (or, without notes, the state) are in iCloud and not on this device yet.
    public var inCloud: Bool

    public init(folder: LectureFolder, course: URL, title: String, date: Date?, titleIsPlaceholder: Bool,
                status: LibraryStatus, notes: [URL], transcript: URL?, slides: [URL], audio: [URL],
                length: TimeInterval?, cost: String?, inCloud: Bool) {
        self.folder = folder
        self.course = course
        self.title = title
        self.date = date
        self.titleIsPlaceholder = titleIsPlaceholder
        self.status = status
        self.notes = notes
        self.transcript = transcript
        self.slides = slides
        self.audio = audio
        self.length = length
        self.cost = cost
        self.inCloud = inCloud
    }
}

/// A folder in the library's tree: a folder added to the library, or a subfolder of one that holds lectures
/// somewhere below it (e.g. `Digital Process Engineering/Pflegeprozesse`).
public struct LibraryFolder: Equatable, Sendable, Identifiable {
    public var id: String { url.standardizedFileURL.path }
    public var url: URL
    public var name: String { url.lastPathComponent }
    /// The lecture folders directly in this folder, newest first.
    public var lectures: [LibraryLecture]
    /// Subfolders with lectures somewhere below them, by name; subfolders without any are left out.
    public var children: [LibraryFolder]

    public init(url: URL, lectures: [LibraryLecture], children: [LibraryFolder]) {
        self.url = url
        self.lectures = lectures
        self.children = children
    }

    /// The lectures in this folder and all its subfolders, newest first.
    public var allLectures: [LibraryLecture] {
        (lectures + children.flatMap(\.allLectures)).sorted(by: Library.newestFirst)
    }

    /// This folder or the subfolder below it with `id`.
    public func folder(_ id: String) -> LibraryFolder? {
        if self.id == id { return self }
        return children.lazy.compactMap { $0.folder(id) }.first
    }

    /// The folder names from this folder down to `folder` (which must be below it), e.g.
    /// `["Digital Process Engineering", "Pflegeprozesse"]`; empty when `folder` isn't in this tree.
    public func path(to folder: URL) -> [String] {
        let target = folder.standardizedFileURL.path
        if id == target { return [name] }
        for child in children {
            let below = child.path(to: folder)
            if !below.isEmpty { return [name] + below }
        }
        return []
    }
}

/// Reads course folders into lectures. Only Faden's lecture folders (those with `.faden/`) are listed; other
/// folders only as the way to lectures below them. Files still in iCloud are never read, so a scan doesn't start
/// downloads.
public enum Library {
    /// How many folder levels below an added folder are searched for lectures.
    public static let maxDepth = 5

    /// The lecture folders directly in `course`, newest date first (undated ones last, by name).
    public static func lectures(in course: URL) -> [LibraryLecture] {
        subfolders(of: course).compactMap { lecture(at: $0, course: course) }.sorted(by: newestFirst)
    }

    /// `root` with its lectures and, up to `maxDepth` levels down, every subfolder that holds lectures. Lecture
    /// folders aren't searched further. `root` is returned even when it holds none.
    public static func tree(at root: URL, maxDepth: Int = maxDepth) -> LibraryFolder {
        var lectures: [LibraryLecture] = []
        var children: [LibraryFolder] = []
        for folder in subfolders(of: root) {
            if let lecture = lecture(at: folder, course: root) {
                lectures.append(lecture)
            } else if maxDepth > 0 {
                let child = tree(at: folder, maxDepth: maxDepth - 1)
                if !child.lectures.isEmpty || !child.children.isEmpty { children.append(child) }
            }
        }
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return LibraryFolder(url: root, lectures: lectures.sorted(by: newestFirst), children: children)
    }

    /// The visible, non-package subfolders of `dir`.
    private static func subfolders(of dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return children.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        }
    }

    /// The lecture in `url`, or nil when it isn't a Faden lecture folder.
    public static func lecture(at url: URL, course: URL) -> LibraryLecture? {
        var isDirectory: ObjCBool = false
        let faden = url.appendingPathComponent(".faden", isDirectory: true)
        guard FileManager.default.fileExists(atPath: faden.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }

        let folder = LectureFolder(url: url)
        let files = LibraryFile.list(url)
        let notes = files.filter { isNotes($0.url.lastPathComponent) }
            .sorted { notesOrder($0.url.lastPathComponent) > notesOrder($1.url.lastPathComponent) }
        let stateFile = LibraryFile.list(faden).first { $0.url.lastPathComponent == "state.json" }
        let state = stateFile.flatMap { $0.isDownloaded ? PipelineState.saved(in: folder) : nil }
        let (date, title) = parse(folderName: url.lastPathComponent)

        let status: LibraryStatus = switch state?.stage {
        case .ready?: .ready
        case .done?: notes.isEmpty ? .notesMissing : .done
        case .failed?: .failed(stage: state?.failedStage, error: state?.error)
        case let stage?: .interrupted(stage)
        case nil: notes.isEmpty ? .unknown : .done
        }
        let newest = notes.first
        let transcript = files.first { $0.url.lastPathComponent == "transcript.md" }
        let audio = state?.audio ?? folder.audioPartURLs()

        return LibraryLecture(
            folder: folder, course: course, title: title, date: date,
            titleIsPlaceholder: state?.titleIsPlaceholder ?? false, status: status,
            notes: notes.map(\.url), transcript: transcript?.url, slides: state?.slides ?? [], audio: audio,
            length: length(of: folder), cost: newest.flatMap { $0.isDownloaded ? cost(inNotes: $0.url) : nil },
            inCloud: newest.map { !$0.isDownloaded } ?? (stateFile.map { !$0.isDownloaded } ?? false))
    }

    /// `2026-10-23 Consensus and Raft` → (23 Oct 2026, `Consensus and Raft`). A name without a leading date
    /// keeps its whole name as the title; a bare date gets the title `Lecture`.
    public static func parse(folderName name: String) -> (date: Date?, title: String) {
        let prefix = String(name.prefix(10))
        guard prefix.count == 10, let date = dayFormatter.date(from: prefix) else { return (nil, name) }
        let rest = name.dropFirst(10).trimmingCharacters(in: .whitespaces)
        return (date, rest.isEmpty ? "Lecture" : rest)
    }

    /// When a `notes (re-run yyyy-MM-dd HH-mm).md` was written; nil for `notes.md` (the first run) and other names.
    public static func rerunDate(ofNotes name: String) -> Date? {
        guard let range = name.range(of: "(re-run ") else { return nil }
        let stamp = name[range.upperBound...].prefix(16)
        return rerunFormatter.date(from: String(stamp))
    }

    /// The cost line of a notes header (`> Cost: $0.82 (…)`), shortened to `$0.82`, or `Subscription`.
    /// nil without a header or when the price was unknown.
    public static func cost(inNotesText text: String) -> String? {
        // The header sits right under the title; don't scan the whole notes.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20) {
            guard line.hasPrefix("> Cost: ") else { continue }
            let value = line.dropFirst("> Cost: ".count)
            if value.hasPrefix("Claude subscription") { return "Subscription" }
            if value.hasPrefix("$") { return String(value.prefix { !$0.isWhitespace }) }
            return nil
        }
        return nil
    }

    // MARK: - Helpers

    static func isNotes(_ name: String) -> Bool {
        name.hasPrefix("notes") && name.hasSuffix(".md")
    }

    /// Sorts the first run (`notes.md`) before its re-runs, and re-runs by their stamp, then by the numeric
    /// suffix `LectureFolder.newNotesURL` adds when a stamp is taken (` (2)`, ` (3)`, …).
    static func notesOrder(_ name: String) -> (String, Int, String) {
        guard let range = name.range(of: "(re-run ") else { return ("", 0, name == "notes.md" ? "" : name) }
        let stamp = String(name[range.upperBound...].prefix(16))
        let rest = name[range.upperBound...].dropFirst(16)  // `).md` or `) (2).md`
        let suffix = rest.hasPrefix(") (") ? Int(rest.dropFirst(3).prefix { $0.isNumber }) ?? 1 : 1
        return (stamp, suffix, name)
    }

    public static func newestFirst(_ a: LibraryLecture, _ b: LibraryLecture) -> Bool {
        switch (a.date, b.date) {
        case let (x?, y?) where x != y: x > y
        case (_?, nil): true
        case (nil, _?): false
        default: a.folder.url.lastPathComponent.localizedStandardCompare(b.folder.url.lastPathComponent) == .orderedDescending
        }
    }

    private static func length(of folder: LectureFolder) -> TimeInterval? {
        guard let meta = LibraryFile.list(folder.transcriptMetaURL.deletingLastPathComponent())
                .first(where: { $0.url.lastPathComponent == "transcript.json" }), meta.isDownloaded,
              let data = try? Data(contentsOf: meta.url),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        else { return nil }
        return transcript.segments.map(\.end).max()
    }

    private static func cost(inNotes url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return cost(inNotesText: String(decoding: head, as: UTF8.self))
    }

    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let rerunFormatter = formatter("yyyy-MM-dd HH-mm")

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = pattern
        f.isLenient = false
        return f
    }
}

/// A file in a synced folder, which may still be in iCloud.
public struct LibraryFile: Equatable, Sendable {
    /// The file's real location, also for a placeholder named `.<name>.icloud`.
    public var url: URL
    public var isDownloaded: Bool

    /// The files in `dir`, hidden ones included, with iCloud placeholders under their real names.
    public static func list(_ dir: URL) -> [LibraryFile] {
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return items.map { item in
            let name = item.lastPathComponent
            if let real = realName(ofPlaceholder: name) {
                return LibraryFile(url: dir.appendingPathComponent(real), isDownloaded: false)
            }
            return LibraryFile(url: item, isDownloaded: isDownloaded(item))
        }
    }

    /// `.notes.md.icloud` → `notes.md`; nil for a name that isn't an iCloud placeholder.
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Whether the file's contents are on this device: always for a file outside iCloud.
    public static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        // Resource values are cached per URL instance; read them fresh.
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus
        else { return FileManager.default.fileExists(atPath: url.path) }
        return status == .current || status == .downloaded
    }
}
