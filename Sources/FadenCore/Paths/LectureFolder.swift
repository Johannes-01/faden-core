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

    /// The lecture's recorded parts in order: `audio.m4a` (part 1), then `audio-2.m4a`, `audio-3.m4a`, ...
    public func audioPartURLs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files
            .compactMap { file in Self.partNumber(of: file.lastPathComponent).map { (number: $0, url: file) } }
            .sorted { $0.number < $1.number }
            .map(\.url)
    }

    /// Where the next recorded part goes: `audio.m4a` for the first, otherwise one past the highest part
    /// (`audio-2.m4a`, `audio-3.m4a`, ...), so a gap never leads back to an earlier name. Never an existing file.
    public func nextAudioURL() -> URL {
        let highest = audioPartURLs().compactMap { Self.partNumber(of: $0.lastPathComponent) }.max() ?? 0
        var n = highest + 1
        while true {
            let candidate = n == 1 ? audioURL : url.appendingPathComponent("audio-\(n).m4a")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// 1 for `audio.m4a`, N for `audio-N.m4a` (N ≥ 2), nil for other names.
    static func partNumber(of name: String) -> Int? {
        if name == "audio.m4a" { return 1 }
        guard name.hasPrefix("audio-"), name.hasSuffix(".m4a") else { return nil }
        let digits = name.dropFirst(6).dropLast(4)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let n = Int(digits), n >= 2 else { return nil }
        return n
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
