import Foundation
import PDFKit

public struct ReprocessRequest: Sendable {
    /// In playback order.
    public var recordings: [URL]
    public var courseFolder: URL
    public var slides: [URL]
    public var userNotes: URL?
    public var styleID: String
    public var allowAdditions: Bool
    public var forceRetranscribe: Bool

    public init(recordings: [URL], courseFolder: URL, slides: [URL], userNotes: URL?, styleID: String,
                allowAdditions: Bool, forceRetranscribe: Bool) {
        self.recordings = recordings
        self.courseFolder = courseFolder
        self.slides = slides
        self.userNotes = userNotes
        self.styleID = styleID
        self.allowAdditions = allowAdditions
        self.forceRetranscribe = forceRetranscribe
    }
}

public enum ReprocessPlannerError: Error, Equatable {
    case noRecordings
}

/// Decides where a "Process again" result goes and gathers its audio (spec §6.1).
public enum ReprocessPlanner {
    /// Uses the first recording's lecture folder when it sits in `courseFolder`, otherwise creates a new one.
    /// Recordings outside any lecture folder are copied in; those in lecture folders are referenced in place.
    public static func plan(_ r: ReprocessRequest, now: Date) throws -> (folder: LectureFolder, state: PipelineState) {
        guard let first = r.recordings.first else { throw ReprocessPlannerError.noRecordings }

        let folder: LectureFolder
        let titleIsPlaceholder: Bool
        var previous: PipelineState?
        let firstParent = first.deletingLastPathComponent()
        if LectureFolder.isLectureFolder(firstParent), isSameDirectory(firstParent.deletingLastPathComponent(), r.courseFolder) {
            folder = LectureFolder(url: firstParent)
            previous = previousState(of: folder)
            // Keep the existing folder's name unless it still carries a placeholder.
            titleIsPlaceholder = r.slides.isEmpty && (previous?.titleIsPlaceholder ?? false)
        } else {
            let title = r.slides.first.map(title(ofSlide:)) ?? "Lecture"
            folder = try LectureFolder.create(in: r.courseFolder, date: now, title: title)
            titleIsPlaceholder = r.slides.isEmpty
        }

        var audio: [URL] = []
        for recording in r.recordings {
            if LectureFolder.isLectureFolder(recording.deletingLastPathComponent()) {
                audio.append(recording)
            } else {
                let target = try freeAudioURL(in: folder.url, ext: recording.pathExtension.lowercased())
                try FileManager.default.copyItem(at: recording, to: target)
                audio.append(target)
            }
        }

        // The recording's pauses live only in the state; keep them while the audio is the same.
        let markers = previous.flatMap { samePaths($0.audio, audio) ? $0.markers : nil } ?? []
        let state = PipelineState(
            audio: audio, slides: r.slides, userNotes: r.userNotes, styleID: r.styleID,
            allowAdditions: r.allowAdditions, forceRetranscribe: r.forceRetranscribe,
            titleIsPlaceholder: titleIsPlaceholder, markers: markers)
        return (folder, state)
    }

    /// The PDF's document title if set, otherwise its file name.
    static func title(ofSlide url: URL) -> String {
        let attribute = PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let title = attribute?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? LectureFolder.title(fromSlide: url) : title
    }

    /// `audio.<ext>`, then `audio-2.<ext>`, `audio-3.<ext>`, …: the first name whose stem no file in `dir`
    /// uses yet, whatever its extension, so parts stay numbered and nothing is overwritten.
    static func freeAudioURL(in dir: URL, ext: String) throws -> URL {
        let taken = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .map { ($0 as NSString).deletingPathExtension })
        var stem = "audio"
        var n = 2
        while taken.contains(stem) {
            stem = "audio-\(n)"
            n += 1
        }
        return dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
    }

    private static func previousState(of folder: LectureFolder) -> PipelineState? {
        guard let data = try? Data(contentsOf: folder.stateURL) else { return nil }
        return try? JSONDecoder().decode(PipelineState.self, from: data)
    }

    private static func samePaths(_ a: [URL], _ b: [URL]) -> Bool {
        func paths(_ urls: [URL]) -> [String] { urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path } }
        return paths(a) == paths(b)
    }

    private static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
