import AVFoundation
import Foundation

/// Joins a session's CAF segments into one AAC `.m4a`.
public enum AudioFinalizer {
    public enum FinalizeError: Error, Equatable {
        case noSegments
        case exportUnavailable
    }

    /// Concatenates `segments` in the given order and exports them to `output` as AAC `.m4a`
    /// (`AVAssetExportPresetAppleM4A`; the preset picks the bitrate).
    /// Never deletes the inputs: the caller removes the segment directory after success.
    /// Fails if `output` already exists, so a finished file is never overwritten.
    /// Segments without audio (e.g. an empty file from a crash right after a roll) are skipped.
    public static func finalize(segments: [URL], to output: URL) async throws {
        guard !segments.isEmpty else { throw FinalizeError.noSegments }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw FinalizeError.exportUnavailable }

        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let range = try await source.load(.timeRange)
            guard range.duration > .zero else { continue }
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw FinalizeError.noSegments }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw FinalizeError.exportUnavailable }
        try await export.export(to: output, as: .m4a)
    }
}
