import Foundation

/// A per-lecture folder holding notes, transcript, audio and `.faden` state.
public struct LectureFolder: Sendable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var notesURL: URL { url.appendingPathComponent("notes.md") }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var audioURL: URL { url.appendingPathComponent("audio.m4a") }
    public var stateURL: URL { fadenDirectory.appendingPathComponent("state.json") }
    public var transcriptMetaURL: URL { fadenDirectory.appendingPathComponent("transcript.json") }
    /// Recorded segments the finaliser couldn't read, kept rather than deleted.
    public var damagedURL: URL { fadenDirectory.appendingPathComponent("damaged", isDirectory: true) }

    private var fadenDirectory: URL { url.appendingPathComponent(".faden", isDirectory: true) }

    /// Creates `yyyy-MM-dd <title>` inside `course`, appending ` (2)`, ` (3)`, ... if taken.
    public static func create(in course: URL, date: Date, title: String) throws -> LectureFolder {
        let fm = FileManager.default
        try fm.createDirectory(at: course, withIntermediateDirectories: true)
        let url = uniqueURL(in: course, baseName: baseName(date: date, title: title))
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return LectureFolder(url: url)
    }

    /// Renames this folder to `yyyy-MM-dd <title>` in the same parent, with the same suffixing as `create`.
    public func rename(toTitle title: String, date: Date) throws -> LectureFolder {
        let parent = url.deletingLastPathComponent()
        let base = Self.baseName(date: date, title: title)
        if url.lastPathComponent == base { return self }
        let target = Self.uniqueURL(in: parent, baseName: base)
        try FileManager.default.moveItem(at: url, to: target)
        return LectureFolder(url: target)
    }

    public static func sanitise(_ title: String) -> String {
        let replaced = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let collapsed = replaced
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let capped = String(collapsed.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.precomposedStringWithCanonicalMapping
    }

    public static func title(fromSlide url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
    }

    public static func isLectureFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".faden/state.json").path)
    }

    /// `notes.md` if free, otherwise `notes (re-run yyyy-MM-dd HH-mm).md` (with a numeric suffix if needed).
    public func newNotesURL(now: Date) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: notesURL.path) { return notesURL }
        let stamp = Self.format(now, "yyyy-MM-dd HH-mm")
        var candidate = url.appendingPathComponent("notes (re-run \(stamp)).md")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathComponent("notes (re-run \(stamp)) (\(n)).md")
            n += 1
        }
        return candidate
    }

    private static func baseName(date: Date, title: String) -> String {
        let prefix = format(date, "yyyy-MM-dd")
        let clean = sanitise(title)
        return clean.isEmpty ? prefix : "\(prefix) \(clean)"
    }

    private static func uniqueURL(in parent: URL, baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
