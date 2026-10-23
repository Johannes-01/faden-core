import Foundation

/// A note style: a prompt fragment plus a little metadata from the file's front matter.
public struct NoteStyle: Equatable, Sendable {
    /// The file name without `.md`, e.g. `C-red-line`.
    public var id: String
    public var name: String
    public var requiresSlides: Bool
    /// The style to use instead when `requiresSlides` and no slides are attached.
    public var fallbackID: String?
    public var prompt: String

    public init(id: String, name: String, requiresSlides: Bool, fallbackID: String?, prompt: String) {
        self.id = id
        self.name = name
        self.requiresSlides = requiresSlides
        self.fallbackID = fallbackID
        self.prompt = prompt
    }
}

public enum StyleStoreError: Error, Equatable {
    case notFound(String)
    case malformed(String)
}

/// The user-editable style files in `~/Library/Application Support/Faden/styles`.
public struct StyleStore: Sendable {
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Faden/styles", directoryHint: .isDirectory)
    }

    public let dir: URL

    public init(dir: URL = StyleStore.defaultDirectory) {
        self.dir = dir
    }

    /// Copies the bundled styles into `dir`, leaving files the user already has untouched.
    public func installDefaultsIfMissing() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundled = Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: "styles") ?? []
        for source in bundled {
            let target = dir.appendingPathComponent(source.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                try fm.copyItem(at: source, to: target)
            }
        }
    }

    /// All readable styles, sorted by id. Files that don't parse are skipped.
    public func all() throws -> [NoteStyle] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .compactMap { try? load($0) }
            .sorted { $0.id < $1.id }
    }

    /// The style with `id`, or its fallback when it needs slides and there are none.
    public func resolve(id: String, hasSlides: Bool) throws -> NoteStyle {
        let style = try load(id: id)
        if style.requiresSlides, !hasSlides, let fallback = style.fallbackID {
            return try load(id: fallback)
        }
        return style
    }

    private func load(id: String) throws -> NoteStyle {
        let url = dir.appendingPathComponent(id + ".md")
        guard FileManager.default.fileExists(atPath: url.path) else { throw StyleStoreError.notFound(id) }
        return try load(url)
    }

    private func load(_ url: URL) throws -> NoteStyle {
        let id = url.deletingPathExtension().lastPathComponent
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw StyleStoreError.malformed(id) }
        return try Self.parse(id: id, text: text)
    }

    /// Parses `---` / `key: value` lines / `---` followed by the prompt body. Unknown keys are ignored;
    /// a leading byte order mark (as some Windows editors write) is skipped.
    static func parse(id: String, text: String) throws -> NoteStyle {
        let unmarked = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = unmarked.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { throw StyleStoreError.malformed(id) }

        var fields: [String: String] = [:]
        for line in lines[1..<close] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw StyleStoreError.malformed(id) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let requiresSlides: Bool
        switch fields["requires_slides"]?.lowercased() {
        case nil, "false": requiresSlides = false
        case "true": requiresSlides = true
        default: throw StyleStoreError.malformed(id)
        }
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        let fallback = fields["fallback"].flatMap { $0.isEmpty ? nil : $0 }
        let prompt = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return NoteStyle(id: id, name: name, requiresSlides: requiresSlides, fallbackID: fallback, prompt: prompt)
    }
}
