import AVFoundation
import Foundation
import os

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
    /// Segments that cannot be loaded or hold no audio (e.g. an empty or corrupt file from a crash
    /// right after a roll) are skipped and logged; throws `noSegments` if none is usable.
    /// Returns the skipped segments, so the caller can keep them.
    @discardableResult
    public static func finalize(segments: [URL], to output: URL) async throws -> [URL] {
        guard !segments.isEmpty else { throw FinalizeError.noSegments }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw FinalizeError.exportUnavailable }

        var cursor = CMTime.zero
        var skipped: [URL] = []
        for url in segments {
            do {
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                    log.warning("Skipping segment without audio track: \(url.lastPathComponent, privacy: .public)")
                    skipped.append(url)
                    continue
                }
                let range = try await source.load(.timeRange)
                guard range.duration > .zero else {
                    log.warning("Skipping empty segment: \(url.lastPathComponent, privacy: .public)")
                    skipped.append(url)
                    continue
                }
                try track.insertTimeRange(range, of: source, at: cursor)
                cursor = cursor + range.duration
            } catch {
                log.error("Skipping unreadable segment \(url.lastPathComponent, privacy: .public): \(error)")
                skipped.append(url)
            }
        }
        guard cursor > .zero else { throw FinalizeError.noSegments }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw FinalizeError.exportUnavailable }
        try await export.export(to: output, as: .m4a)
        return skipped
    }

    private static let log = Logger(subsystem: "de.haick.faden", category: "AudioFinalizer")
}
