import Foundation

/// Turns picked files and folders into the ordered recordings list of "Process again", and reorders it.
public enum RecordingList {
    /// The audio file types the picker accepts.
    public static let audioExtensions = ["m4a", "mp3", "wav", "aiff", "caf"]

    public struct Rejection: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case unsupportedType
            case notLectureFolder
            case noAudio
        }

        public var url: URL
        public var reason: Reason

        public init(url: URL, reason: Reason) {
            self.url = url
            self.reason = reason
        }

        /// One line for the inline message.
        public var message: String {
            switch reason {
            case .unsupportedType: "\(url.lastPathComponent) isn't an audio file (m4a, mp3, wav, aiff, caf)."
            case .notLectureFolder: "\(url.lastPathComponent) isn't a lecture folder."
            case .noAudio: "\(url.lastPathComponent) has no audio files."
            }
        }
    }

    /// Picked files stay in pick order. A lecture folder contributes its `audio*.<ext>` files in natural
    /// order (audio, audio-2, …, audio-10). Everything else is returned as rejected.
    public static func expand(_ urls: [URL]) -> (recordings: [URL], rejected: [Rejection]) {
        var recordings: [URL] = []
        var rejected: [Rejection] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                guard LectureFolder.isLectureFolder(url) else {
                    rejected.append(Rejection(url: url, reason: .notLectureFolder))
                    continue
                }
                let audio = audioFiles(in: url)
                if audio.isEmpty { rejected.append(Rejection(url: url, reason: .noAudio)) }
                recordings += audio
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                recordings.append(url)
            } else {
                rejected.append(Rejection(url: url, reason: .unsupportedType))
            }
        }
        return (recordings, rejected)
    }

    /// `expand`, appended to `existing` without repeating a file already listed.
    public static func adding(_ urls: [URL], to existing: [URL]) -> (recordings: [URL], rejected: [Rejection]) {
        let expanded = expand(urls)
        var list = existing
        for url in expanded.recordings where !list.contains(url) { list.append(url) }
        return (list, expanded.rejected)
    }

    /// The listed recordings whose file no longer exists, e.g. deleted in Finder after they were added.
    public static func missing(_ recordings: [URL]) -> Set<URL> {
        Set(recordings.filter { !FileManager.default.fileExists(atPath: $0.path) })
    }

    public static func movedUp<T>(_ list: [T], at index: Int) -> [T] {
        guard list.indices.contains(index), index > 0 else { return list }
        var result = list
        result.swapAt(index, index - 1)
        return result
    }

    public static func movedDown<T>(_ list: [T], at index: Int) -> [T] {
        guard list.indices.contains(index), index < list.count - 1 else { return list }
        var result = list
        result.swapAt(index, index + 1)
        return result
    }

    /// `audio.<ext>`, `audio-2.<ext>`, … sorted by part number; other names are ignored.
    private static func audioFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (part: Int, name: String)? in
            let file = name as NSString
            guard audioExtensions.contains(file.pathExtension.lowercased()),
                  let part = partNumber(stem: file.deletingPathExtension) else { return nil }
            return (part, name)
        }
        .sorted { ($0.part, $0.name) < ($1.part, $1.name) }
        .map { folder.appendingPathComponent($0.name) }
    }

    private static func partNumber(stem: String) -> Int? {
        if stem == "audio" { return 1 }
        guard stem.hasPrefix("audio-"), let n = Int(stem.dropFirst(6)), n >= 2 else { return nil }
        return n
    }
}
