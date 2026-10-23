import Foundation

public enum Pricing {
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
    public var date: Date
    public var lecture: String
    public var model: String
    public var usage: Usage
    public var usd: Double?

    public init(date: Date, lecture: String, model: String, usage: Usage, usd: Double?) {
        self.date = date
        self.lecture = lecture
        self.model = model
        self.usage = usage
        self.usd = usd
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
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sum = 0.0
        for line in data.split(separator: 0x0A) {
            guard let r = try? decoder.decode(CostRecord.self, from: Data(line)) else { continue }
            if let since, r.date < since { continue }
            sum += r.usd ?? 0
        }
        return sum
    }
}
