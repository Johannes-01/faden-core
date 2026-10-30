import Foundation

public enum Pricing {
    /// Who serves `model`, e.g. `anthropic`; nil for an unknown model.
    public static func provider(model: String) -> String? {
        model.hasPrefix("claude-") ? "anthropic" : nil
    }

    /// USD for one call, or nil for an unknown model. Prices are per 1M tokens.
    public static func usd(model: String, usage: Usage) -> Double? {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
        switch model {
        case "claude-opus-5-5":
            (input, output, cacheRead, cacheWrite) = (4.00, 20.00, 0.20, 5.00)
        case "claude-haiku-5-5":
            let prompt = usage.inputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens
            let long = prompt > 100_000
            input = long ? 0.50 : 0.10
            output = long ? 2.50 : 0.50
            cacheRead = input * 0.10
            cacheWrite = input * 1.25
        default:
            return nil
        }
        let total = Double(usage.inputTokens) * input
            + Double(usage.outputTokens) * output
            + Double(usage.cacheReadInputTokens) * cacheRead
            + Double(usage.cacheCreationInputTokens) * cacheWrite
        return total / 1_000_000
    }
}

public struct CostRecord: Codable, Sendable {
    /// The pipeline stage that made a call.
    public enum Step: String, Codable, Sendable {
        case notes, verify
    }

    /// How a call was paid for.
    public enum Billing: String, Codable, Sendable {
        case api, subscription
    }

    public var date: Date
    public var lecture: String
    /// nil in lines written before Faden recorded it, as are `provider`, `billing` and `apiUSD`.
    public var step: Step?
    /// E.g. `anthropic`.
    public var provider: String?
    public var model: String
    public var billing: Billing?
    public var usage: Usage
    /// What the call cost: 0 on the subscription, nil for a model without a known price.
    public var usd: Double?
    /// What the call costs with an API key, also when it ran on the subscription.
    public var apiUSD: Double?
    /// What a subscription call used of the limits; nil for API-key calls, subscription calls without both
    /// readings, and lines written before Faden recorded it.
    public var limitUse: LimitUse?

    public init(date: Date, lecture: String, step: Step? = nil, provider: String? = nil, model: String,
                billing: Billing? = nil, usage: Usage, usd: Double?, apiUSD: Double? = nil, limitUse: LimitUse? = nil) {
        self.date = date
        self.lecture = lecture
        self.step = step
        self.provider = provider
        self.model = model
        self.billing = billing
        self.usage = usage
        self.usd = usd
        self.apiUSD = apiUSD
        self.limitUse = limitUse
    }

    public init(date: Date, lecture: String, step: Step, call: PaidCall) {
        self.init(
            date: date, lecture: lecture, step: step, provider: Pricing.provider(model: call.model), model: call.model,
            billing: call.subscription == nil ? .api : .subscription, usage: call.usage, usd: call.usd,
            apiUSD: Pricing.usd(model: call.model, usage: call.usage), limitUse: call.limitUse)
    }
}

/// Append-only JSON-lines ledger of API costs.
public struct CostLedger: Sendable {
    public let file: URL

    public init(file: URL = CostLedger.defaultFile) {
        self.file = file
    }

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faden", isDirectory: true)
            .appendingPathComponent("costs.jsonl")
    }

    public func append(_ r: CostRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Without it the key order changes from launch to launch.
        encoder.outputFormatting = .sortedKeys
        var line = try encoder.encode(r)
        line.append(0x0A)
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            try line.write(to: file)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Sums `usd` of records dated at or after `since` (all when nil). Undecodable lines are skipped.
    public func total(since: Date?) throws -> Double {
        try records(since: since).reduce(0) { $0 + ($1.usd ?? 0) }
    }

    /// Sums what the records dated at or after `since` (all when nil) cost with an API key, also those that ran on
    /// the subscription. Lines without `apiUSD` are priced from their tokens; unknown models count as 0.
    public func apiTotal(since: Date?) throws -> Double {
        try records(since: since).reduce(0) { $0 + ($1.apiUSD ?? Pricing.usd(model: $1.model, usage: $1.usage) ?? 0) }
    }

    /// Sums the limit use of records dated at or after `since` (all when nil), or nil when none has one. A window
    /// that started over during a call counts as 0.
    public func limitUse(since: Date?) throws -> LimitUse? {
        let uses = try records(since: since).compactMap(\.limitUse)
        guard !uses.isEmpty else { return nil }
        return LimitUse(session: uses.reduce(0) { $0 + ($1.session ?? 0) }, week: uses.reduce(0) { $0 + ($1.week ?? 0) })
    }

    private func records(since: Date?) throws -> [CostRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            guard let r = try? decoder.decode(CostRecord.self, from: Data(line)) else { return nil }
            if let since, r.date < since { return nil }
            return r
        }
    }
}
