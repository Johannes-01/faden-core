import Foundation
import Testing
@testable import FadenCore

@Suite struct TranscriptTests {
    private func transcript(_ segments: [(Double, Double, String)], markers: [TranscriptMarker] = []) -> Transcript {
        Transcript(
            segments: segments.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) },
            markers: markers, language: "de", model: "m")
    }

    @Test func timestampFormat() {
        let md = transcript([(3725, 3730, "Hallo")]).markdown()
        #expect(md.hasPrefix("# Transcript"))
        #expect(md.contains("[01:02:05] Hallo"))
    }

    @Test func concatenateOffsetsSecondPart() {
        let a = transcript([(0, 90, "eins")])
        let b = transcript([(5, 10, "zwei")])
        let joined = Transcript.concatenate([(file: "a.m4a", transcript: a, duration: 100), (file: "b.m4a", transcript: b, duration: 20)])
        #expect(joined.segments[1].start == 105)
        #expect(joined.segments[1].end == 110)
        let md = joined.markdown()
        #expect(md.contains("— Part 2: b.m4a starts at [00:01:40] —"))
        #expect(md.contains("— Part 1: a.m4a starts at [00:00:00] —"))
    }

    @Test func concatenateSinglePartAddsNoMarker() {
        let joined = Transcript.concatenate([(file: "a.m4a", transcript: transcript([(0, 1, "x")]), duration: 1)])
        #expect(joined.markers.isEmpty)
    }

    @Test func concatenateShiftsMarkersAndEmptyPartAdvancesByDuration() {
        let a = transcript([(0, 100, "eins")])
        let empty = transcript([])
        let c = transcript([(2, 3, "drei")], markers: [.pause(at: 1, duration: 30)])
        let joined = Transcript.concatenate([
            (file: "a", transcript: a, duration: 100), (file: "b", transcript: empty, duration: 50),
            (file: "c", transcript: c, duration: 10),
        ])
        #expect(joined.segments[1].start == 152)
        #expect(joined.markers.contains(.pause(at: 151, duration: 30)))
        #expect(joined.markers.contains(.part(index: 3, file: "c", at: 150)))
    }

    @Test func concatenateTakesFirstModelAndFirstLanguage() {
        let a = Transcript(segments: [], markers: [], language: nil, model: "m1")
        let b = Transcript(segments: [], markers: [], language: "en", model: "m2")
        let c = Transcript(segments: [], markers: [], language: "de", model: "m3")
        let joined = Transcript.concatenate([
            (file: "a", transcript: a, duration: 1), (file: "b", transcript: b, duration: 1),
            (file: "c", transcript: c, duration: 1),
        ])
        #expect(joined.model == "m1")
        #expect(joined.language == "en")
    }

    @Test func outOfOrderMarkersAreSorted() {
        let t = transcript([(0, 1, "a"), (100, 101, "b")],
                           markers: [.pause(at: 60, duration: 5), .pause(at: 30, duration: 5)])
        let lines = t.markdown().split(separator: "\n").map(String.init)
        let i30 = lines.firstIndex { $0.contains("[00:00:30]") }
        let i60 = lines.firstIndex { $0.contains("[00:01:00]") }
        #expect(i30 != nil && i60 != nil && i30! < i60!)
    }

    @Test func pauseMarkerRendered() {
        let t = transcript([(1800, 1801, "vorher"), (1900, 1901, "nachher")],
                           markers: [.pause(at: 1865, duration: 155)])
        let lines = t.markdown().split(separator: "\n").map(String.init)
        let i = lines.firstIndex(of: "— paused at [00:31:05] for 2 min 35 s —")
        #expect(i != nil)
        #expect(lines[i! - 1].hasPrefix("[00:30:00]"))
        #expect(lines[i! + 1].hasPrefix("[00:31:40]"))
    }

    @Test func shortPauseAndTrailingMarker() {
        let t = transcript([(0, 1, "a")], markers: [.pause(at: 50, duration: 45)])
        #expect(t.markdown().hasSuffix("— paused at [00:00:50] for 45 s —\n"))
    }

    @Test func emptyDetection() {
        #expect(transcript([(0, 1, "…"), (1, 2, "…"), (2, 3, "…")]).isEffectivelyEmpty)
        #expect(!transcript([(0, 1, String(repeating: "a", count: 200))]).isEffectivelyEmpty)
    }

    @Test func codableRoundTrip() throws {
        let t = transcript([(0, 1, "a")], markers: [.part(index: 1, file: "a", at: 0), .pause(at: 1, duration: 2)])
        let back = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}
