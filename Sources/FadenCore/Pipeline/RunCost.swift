import Foundation

extension PipelineState {
    /// The run's cost: the sum of `Pricing.usd` over the notes and verify calls, as the notes header
    /// shows it. nil when any call's model has no known price. No calls sum to 0.
    public var costUSD: Double? {
        var sum = 0.0
        for call in [notesCall, verifyCall].compactMap({ $0 }) {
            guard let price = Pricing.usd(model: call.model, usage: call.usage) else { return nil }
            sum += price
        }
        return sum
    }
}

public enum RunCost {
    /// "$0.84" for a known cost; nil when the price is unknown.
    public static func text(_ usd: Double?) -> String? {
        usd.map { String(format: "$%.2f", $0) }
    }

    /// The cost text of the lecture's saved state, e.g. "$0.84", or nil if unreadable or unpriced.
    public static func text(for folder: LectureFolder) -> String? {
        PipelineState.saved(in: folder).flatMap { text($0.costUSD) }
    }
}

/// What the Quit button does for the current app state.
public enum QuitPolicy: Equatable, Sendable {
    case quitNow
    /// A recording is running, paused or recovered: Stop saves it first.
    case confirmStopAndSave
    /// Stop is still saving the audio; quitting waits.
    case waitForSave
    /// A pipeline run is in progress and would be stopped.
    case confirmStopRun

    public static func action(hasUnfinishedRecording: Bool, isFinishing: Bool, isProcessing: Bool) -> QuitPolicy {
        if isFinishing { return .waitForSave }
        if hasUnfinishedRecording { return .confirmStopAndSave }
        if isProcessing { return .confirmStopRun }
        return .quitNow
    }
}
