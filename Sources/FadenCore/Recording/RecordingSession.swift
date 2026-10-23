import Foundation

public enum RecordingPhase: String, Codable, Sendable {
    case recording, paused
    /// Capture has ended and the audio is being saved into a lecture folder. Still unfinished:
    /// a crash or a failed save leaves the session recoverable until the audio is in place.
    case finishing
    case stopped
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

public enum RecordingSessionError: Error, Equatable {
    case alreadyStopped
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
    /// The existing lecture this recording continues ("Continue recording"); Stop saves its audio there as
    /// the next part. nil starts a new lecture, as in session files written before parts existed.
    public var lectureFolder: URL?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        phase: RecordingPhase = .recording,
        courseFolder: URL,
        slides: [URL] = [],
        notesFile: URL? = nil,
        pauses: [PauseRecord] = [],
        segmentCount: Int = 0,
        lectureFolder: URL? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.phase = phase
        self.courseFolder = courseFolder
        self.slides = slides
        self.notesFile = notesFile
        self.pauses = pauses
        self.segmentCount = segmentCount
        self.lectureFolder = lectureFolder
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

    /// recording or paused -> finishing, when capture ends and saving begins. A pause still open is
    /// closed at `now`. Returns false and changes nothing otherwise.
    @discardableResult
    public mutating func beginFinishing(now: Date = Date()) -> Bool {
        guard phase == .recording || phase == .paused else { return false }
        if phase == .paused { closeOpenPause(at: now) }
        phase = .finishing
        return true
    }

    /// recording, paused or finishing -> stopped. A pause still open is closed at `now`.
    @discardableResult
    public mutating func stop(now: Date = Date()) -> Bool {
        guard phase != .stopped else { return false }
        if phase == .paused { closeOpenPause(at: now) }
        phase = .stopped
        return true
    }

    /// Brings the session into `.recording` before capture (re)starts, e.g. for a session
    /// recovered after a crash: a paused session is resumed (its open pause closed at `now`),
    /// a recording one is left as is, a finishing one (its save never completed) records again,
    /// a stopped one is rejected.
    public mutating func prepareForRecording(at recordedTime: TimeInterval, now: Date = Date()) throws {
        switch phase {
        case .recording: return
        case .paused: resume(at: recordedTime, now: now)
        case .finishing: phase = .recording
        case .stopped: throw RecordingSessionError.alreadyStopped
        }
    }

    private mutating func closeOpenPause(at date: Date) {
        guard let last = pauses.indices.last, pauses[last].ended == nil else { return }
        pauses[last].ended = date
    }
}
