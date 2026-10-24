import Foundation

extension PipelineState {
    /// The run's cost: the sum of `Pricing.usd` over the notes and verify calls, as the notes header
    /// shows it. nil when any call's model has no known price. No calls sum to 0.
    public var costUSD: Double? { sum(\.usd) }

    /// What the run costs at API prices, also when it ran on the subscription. nil as for `costUSD`.
    public var apiCostUSD: Double? { sum(\.apiUSD) }

    /// The limits' use after the run's last subscription call; nil when no call ran on the subscription.
    public var subscription: SubscriptionLimits? {
        [notesCall, verifyCall].compactMap { $0 }.last(where: { $0.subscription != nil })?.subscription
    }

    private func sum(_ price: KeyPath<PaidCall, Double?>) -> Double? {
        var sum = 0.0
        for call in [notesCall, verifyCall].compactMap({ $0 }) {
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

    /// "≈ $0.84 at API prices", or nil when the price is unknown.
    public static func apiText(_ usd: Double?) -> String? {
        text(usd).map { "≈ \($0) at API prices" }
    }

    /// The finished run for the notification: "48,210 tokens · ≈ $0.84 at API prices · session 12% · week 61%"
    /// when it ran on the subscription, else its cost, e.g. "$0.84". nil when neither is known.
    public static func summary(_ state: PipelineState) -> String? {
        guard let limits = state.subscription else { return text(state.costUSD) }
        var tokens = 0
        for u in [state.notesCall, state.verifyCall].compactMap({ $0?.usage }) {
            tokens += u.inputTokens + u.cacheReadInputTokens + u.cacheCreationInputTokens
            tokens += u.outputTokens
        }
        return (["\(tokens.formatted()) tokens"] + [apiText(state.apiCostUSD)].compactMap { $0 } + [limits.text])
            .joined(separator: " · ")
    }

    /// The cost text of the lecture's saved state, e.g. "$0.84", or "≈ $0.84 at API prices" for a run on the
    /// subscription; nil if unreadable or unpriced.
    public static func text(for folder: LectureFolder) -> String? {
        PipelineState.saved(in: folder).flatMap { $0.subscription != nil ? apiText($0.apiCostUSD) : text($0.costUSD) }
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
