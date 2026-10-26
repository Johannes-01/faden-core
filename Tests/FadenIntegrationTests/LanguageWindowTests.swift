import FadenCore
import Testing
@testable import FadenTranscription

@Suite struct LanguageWindowTests {
    @Test func windowsSpreadOverSpeechNotSilence() {
        // 100 s of speech in two clips with a 1000 s silence between them.
        let speech = [SpeechClip(start: 0, end: 50), SpeechClip(start: 1050, end: 1100)]
        #expect(WhisperKitTranscriber.languageWindowStarts(speech: speech, count: 4) == [12.5, 37.5, 1062.5, 1087.5])
    }

    @Test func noSpeechNoWindows() {
        #expect(WhisperKitTranscriber.languageWindowStarts(speech: [], count: 5).isEmpty)
    }
}
