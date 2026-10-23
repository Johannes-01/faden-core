import Foundation

public protocol Transcriber: Sendable {
    var modelName: String { get }
    func transcribe(audio: URL, language: String?) async throws -> Transcript
}
