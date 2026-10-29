import Foundation

extension PipelineState {
    /// The run's cost: the sum of `Pricing.usd` over the notes and verify calls, as the notes header
    /// shows it. nil when any call's model has no known price. No calls sum to 0.
    public var costUSD: Double? { sum(\.usd) }

    /// Whether any of the run's calls ran on the subscription.
    public var ranOnSubscription: Bool { calls.contains { $0.subscription != nil } }

    /// What the run used of the subscription's limits; nil as for `LimitUse.total(of:)`.
    public var limitUse: LimitUse? { LimitUse.total(of: calls) }

    private var calls: [PaidCall] { [notesCall, verifyCall].compactMap { $0 } }

    private func sum(_ price: KeyPath<PaidCall, Double?>) -> Double? {
        var sum = 0.0
        for call in calls {
            guard let p = call[keyPath: price] else { return nil }
            sum += p
        }
        return sum
    }
}

public enum RunCost {
    /// "$0.84" for a known cost; nil when the price is unknown.
    public static func text(_ usd: Double?) -> String? {
        usd.map { String(format: "$%.2f", $0) }
    }

    /// The finished run for the notification: "48,210 tokens · session +4% · week <1%" when it ran on the
    /// subscription (just the tokens when its limit use is unknown), else its cost, e.g. "$0.84". nil when
    /// the price is unknown.
    public static func summary(_ state: PipelineState) -> String? {
        guard state.ranOnSubscription else { return text(state.costUSD) }
        var tokens = 0
        for u in [state.notesCall, state.verifyCall].compactMap({ $0?.usage }) {
            tokens += u.inputTokens + u.cacheReadInputTokens + u.cacheCreationInputTokens
            tokens += u.outputTokens
        }
        return (["\(tokens.formatted()) tokens"] + [state.limitUse?.text].compactMap { $0 }).joined(separator: " · ")
    }

    /// The cost text of the lecture's saved state, e.g. "$0.84", or "session +4% · week <1%" for a run on the
    /// subscription; nil if unreadable, unpriced or of unknown limit use.
    public static func text(for folder: LectureFolder) -> String? {
        PipelineState.saved(in: folder).flatMap { $0.ranOnSubscription ? $0.limitUse?.text : text($0.costUSD) }
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
