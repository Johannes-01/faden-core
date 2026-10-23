import Foundation

public enum RecordingPhase: String, Codable, Sendable {
    case recording, paused, stopped
}

/// A pause in the recording. `at` is the position in the recorded audio where it happened.
public struct PauseRecord: Codable, Equatable, Sendable {
    public let at: TimeInterval
    public let began: Date
    public var ended: Date?

    public init(at: TimeInterval, began: Date, ended: Date? = nil) {
        self.at = at
        self.began = began
        self.ended = ended
    }

    /// Wall-clock length of the pause, or nil while it is still open.
    public var duration: TimeInterval? {
        ended.map { $0.timeIntervalSince(began) }
    }
}

public struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var phase: RecordingPhase
    public var courseFolder: URL
    public var slides: [URL]
    public var notesFile: URL?
    public var pauses: [PauseRecord]
    public var segmentCount: Int

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        phase: RecordingPhase = .recording,
        courseFolder: URL,
        slides: [URL] = [],
        notesFile: URL? = nil,
        pauses: [PauseRecord] = [],
        segmentCount: Int = 0
    ) {
        self.id = id
        self.startedAt = startedAt
        self.phase = phase
        self.courseFolder = courseFolder
        self.slides = slides
        self.notesFile = notesFile
        self.pauses = pauses
        self.segmentCount = segmentCount
    }

    /// recording -> paused. Returns false and changes nothing otherwise.
    @discardableResult
    public mutating func pause(at recordedTime: TimeInterval, now: Date = Date()) -> Bool {
        guard phase == .recording else { return false }
        pauses.append(PauseRecord(at: recordedTime, began: now))
        phase = .paused
        return true
    }

    /// paused -> recording, closing the open pause. Returns false and changes nothing otherwise.
    @discardableResult
    public mutating func resume(at recordedTime: TimeInterval, now: Date = Date()) -> Bool {
        guard phase == .paused else { return false }
        closeOpenPause(at: now)
        phase = .recording
        return true
    }

    /// recording or paused -> stopped. A pause still open is closed at `now`.
    @discardableResult
    public mutating func stop(now: Date = Date()) -> Bool {
        guard phase != .stopped else { return false }
        if phase == .paused { closeOpenPause(at: now) }
        phase = .stopped
        return true
    }

    private mutating func closeOpenPause(at date: Date) {
        guard let last = pauses.indices.last, pauses[last].ended == nil else { return }
        pauses[last].ended = date
    }
}
