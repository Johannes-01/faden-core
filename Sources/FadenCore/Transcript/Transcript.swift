import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// All times are positions in the recorded audio. `part.index` is the 1-based part number.
public enum TranscriptMarker: Codable, Equatable, Sendable {
    case part(index: Int, file: String, at: TimeInterval)
    case pause(at: TimeInterval, duration: TimeInterval)

    var position: TimeInterval {
        switch self {
        case .part(_, _, let at), .pause(let at, _): at
        }
    }

    func shifted(by offset: TimeInterval) -> TranscriptMarker {
        switch self {
        case .part(let index, let file, let at): .part(index: index, file: file, at: at + offset)
        case .pause(let at, let duration): .pause(at: at + offset, duration: duration)
        }
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var segments: [TranscriptSegment]
    public var markers: [TranscriptMarker]
    public var language: String?
    public var model: String
    /// The names of the audio files transcribed, in order. nil in transcripts saved before it was recorded.
    public var audioFiles: [String]?

    public init(segments: [TranscriptSegment], markers: [TranscriptMarker], language: String?, model: String,
                audioFiles: [String]? = nil) {
        self.segments = segments
        self.markers = markers
        self.language = language
        self.model = model
        self.audioFiles = audioFiles
    }

    /// True when the segments hold fewer than 200 non-whitespace characters in total.
    public var isEffectivelyEmpty: Bool {
        segments.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count } < 200
    }

    public func markdown() -> String {
        var lines = ["# Transcript", ""]
        var pending = markers.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element)[...]
        for segment in segments {
            while let marker = pending.first, marker.position <= segment.start {
                lines.append(Self.line(for: marker))
                pending.removeFirst()
            }
            lines.append("[\(Self.timestamp(segment.start))] \(segment.text)")
        }
        lines.append(contentsOf: pending.map(Self.line(for:)))
        return lines.joined(separator: "\n") + "\n"
    }

    public static func concatenate(_ parts: [(file: String, transcript: Transcript, duration: TimeInterval)]) -> Transcript {
        var segments: [TranscriptSegment] = []
        var markers: [TranscriptMarker] = []
        var offset: TimeInterval = 0
        for (i, part) in parts.enumerated() {
            if parts.count > 1 {
                markers.append(.part(index: i + 1, file: part.file, at: offset))
            }
            segments += part.transcript.segments.map {
                TranscriptSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text)
            }
            markers += part.transcript.markers.map { $0.shifted(by: offset) }
            offset += part.duration
        }
        return Transcript(
            segments: segments, markers: markers,
            language: parts.lazy.compactMap(\.transcript.language).first,
            model: parts.first?.transcript.model ?? "")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    private static func line(for marker: TranscriptMarker) -> String {
        switch marker {
        case .part(let index, let file, let at):
            "— Part \(index): \(file) starts at [\(timestamp(at))] —"
        case .pause(let at, let duration):
            "— paused at [\(timestamp(at))] for \(Self.duration(duration)) —"
        }
    }
}
