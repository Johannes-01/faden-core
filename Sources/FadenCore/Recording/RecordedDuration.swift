import AVFAudio
import Foundation

/// Total audio length of `segments` in seconds, from each file's frame count. Unreadable files
/// (e.g. an empty file from a crash right after a roll) count as zero.
public func recordedDuration(of segments: [URL]) -> TimeInterval {
    segments.reduce(0) { total, url in
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return total }
        return total + Double(file.length) / file.fileFormat.sampleRate
    }
}
