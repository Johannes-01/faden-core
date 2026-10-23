import AVFoundation
import Foundation
import Testing
import FadenCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FADEN_INTEGRATION"] == "1"))
struct AudioFinalizerTests {
    /// Writes a 16 kHz mono Int16 CAF with `/usr/bin/say`. `[[slnc ms]]` inserts silence.
    private func say(_ text: String, to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// Peak absolute sample value in `[from, to)` seconds of the decoded file.
    private func peak(of url: URL, from: TimeInterval, to: TimeInterval) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(from * rate)
        let frames = AVAudioFrameCount((to - from) * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer, frameCount: frames)
        let samples = try #require(buffer.floatChannelData)[0]
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
    }

    @Test func finalizeJoinsSegmentsInOrder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-finalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Speech at the end of segment 1 and the start of segment 2: in the right order the
        // speech sits around the 3 s join and the first second is silent.
        let seg1 = dir.appendingPathComponent("seg-0001.caf")
        let seg2 = dir.appendingPathComponent("seg-0002.caf")
        try say("[[slnc 2600]] eins", to: seg1)
        try say("zwei [[slnc 2600]]", to: seg2)
        let inputDuration = try await duration(of: seg1) + duration(of: seg2)

        let output = dir.appendingPathComponent("audio.m4a")
        try await AudioFinalizer.finalize(segments: [seg1, seg2], to: output)

        #expect(output.pathExtension == "m4a")
        let outDuration = try await duration(of: output)
        #expect(abs(outDuration - 6) <= 0.5)
        #expect(abs(outDuration - inputDuration) <= 0.2)
        #expect(try peak(of: output, from: 0, to: 1) < 0.01)
        #expect(try peak(of: output, from: 2.2, to: 3.8) > 0.05)
        // Inputs are never deleted by the finaliser.
        #expect(FileManager.default.fileExists(atPath: seg1.path))
        #expect(FileManager.default.fileExists(atPath: seg2.path))
    }

    @Test func finalizeThrowsOnNoSegments() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-empty-\(UUID().uuidString).m4a")
        await #expect(throws: (any Error).self) {
            try await AudioFinalizer.finalize(segments: [], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
