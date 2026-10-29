import Foundation

/// The course folders the library shows, kept as bookmarks so they are found again after a move or rename, and
/// (security-scoped) in a sandboxed app or on iPad. Saved by the app, e.g. in UserDefaults.
public struct CourseList: Codable, Equatable, Sendable {
    public struct Course: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var bookmark: Data
        /// Where the folder was when last resolved; shown, and used when the bookmark can't be resolved.
        public var path: String

        public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// In the order they were added.
    public private(set) var courses: [Course]

    public init(courses: [Course] = []) {
        self.courses = courses
    }

    /// Adds `folder` unless it is already listed or inside a listed folder (whose tree shows it as a subfolder);
    /// listed folders inside `folder` are replaced by it. Returns the course showing `folder`, new or existing.
    @discardableResult
    public mutating func add(_ folder: URL) throws -> Course {
        if let existing = course(containing: folder) { return existing }
        let course = Course(id: UUID(), bookmark: try Self.bookmark(for: folder), path: folder.standardizedFileURL.path)
        courses.removeAll { Self.isInside($0.path, course.path) }
        courses.append(course)
        return course
    }

    /// The listed course whose folder is `folder` or one of its parents.
    public func course(containing folder: URL) -> Course? {
        let path = folder.standardizedFileURL.path
        return courses.first { $0.path == path || Self.isInside(path, $0.path) }
    }

    /// `path` is strictly below `parent`.
    static func isInside(_ path: String, _ parent: String) -> Bool {
        path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    public mutating func remove(_ id: UUID) {
        courses.removeAll { $0.id == id }
    }

    /// The listed course whose folder is `folder`, if any.
    public func course(for folder: URL) -> Course? {
        let path = folder.standardizedFileURL.path
        return courses.first { $0.path == path }
    }

    /// Where `course` is now. Follows a moved or renamed folder and updates its saved path and bookmark (hence
    /// mutating). Falls back to the saved path when the bookmark can't be resolved. Starts security-scoped
    /// access, which the app keeps while it runs.
    public mutating func resolve(_ id: UUID) -> URL? {
        guard let i = courses.firstIndex(where: { $0.id == id }) else { return nil }
        var stale = false
        // A plain bookmark (see `bookmark(for:)`) doesn't resolve with the security-scope option.
        var resolved: URL?
        for options in Self.resolveOptions where resolved == nil {
            resolved = try? URL(resolvingBookmarkData: courses[i].bookmark, options: options, relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        }
        guard let url = resolved else { return URL(fileURLWithPath: courses[i].path, isDirectory: true) }
        _ = url.startAccessingSecurityScopedResource()
        let path = url.standardizedFileURL.path
        if stale || path != courses[i].path {
            courses[i].path = path
            if let fresh = try? Self.bookmark(for: url) { courses[i].bookmark = fresh }
        }
        return url
    }

    static func bookmark(for folder: URL) throws -> Data {
        #if os(macOS)
        // A security-scoped bookmark needs the sandbox's bookmark entitlement; without a sandbox a plain one
        // reaches the folder as well.
        if let scoped = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                 relativeTo: nil) {
            return scoped
        }
        #endif
        return try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static var resolveOptions: [URL.BookmarkResolutionOptions] {
        #if os(macOS)
        [[.withSecurityScope, .withoutUI], [.withoutUI]]
        #else
        [[.withoutUI]]
        #endif
    }
}
