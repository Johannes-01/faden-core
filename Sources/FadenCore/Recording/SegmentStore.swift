import Foundation

/// On-disk scratch storage for one recording session: `seg-NNNN.caf` files plus `session.json`.
public struct SegmentStore: Sendable {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Faden/recordings", isDirectory: true)
    }

    public let dir: URL

    public init(root: URL = SegmentStore.defaultRoot, sessionID: UUID) {
        dir = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// The next free `seg-NNNN.caf` URL. Creates the session directory, not the file.
    public func nextSegmentURL() -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String(format: "seg-%04d.caf", segments().count + 1))
    }

    /// Segment files on disk, sorted by name.
    public func segments() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { Self.isSegmentName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func save(_ session: RecordingSession) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(session).write(to: Self.sessionFile(in: dir), options: .atomic)
    }

    public static func load(dir: URL) throws -> RecordingSession {
        try decoder.decode(RecordingSession.self, from: Data(contentsOf: sessionFile(in: dir)))
    }

    /// Sessions under `root` whose phase is not `.stopped`. Directories without a readable `session.json` are skipped.
    public static func unfinished(root: URL) -> [RecordingSession] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .compactMap { try? load(dir: $0) }
            .filter { $0.phase != .stopped }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Removes this session's own directory (app scratch data).
    public func discard() throws {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    private static func sessionFile(in dir: URL) -> URL {
        dir.appendingPathComponent("session.json")
    }

    private static func isSegmentName(_ name: String) -> Bool {
        name.hasPrefix("seg-") && name.hasSuffix(".caf")
            && name.dropFirst(4).dropLast(4).allSatisfy(\.isNumber)
            && name.count > 8
    }

    /// ISO-8601 with milliseconds, so sub-second timing survives a save/load round trip.
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(date.formatted(Self.dateFormat))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            return try Date(try c.decode(String.self), strategy: Self.dateFormat)
        }
        return d
    }
}
