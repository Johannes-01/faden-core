import Foundation
import Testing
@testable import FadenCore

@Suite struct CostLedgerTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("faden-ledger-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("costs.jsonl")
    }

    private func record(_ date: Date, usd: Double?) -> CostRecord {
        CostRecord(date: date, lecture: "L", model: "claude-opus-5-5", usage: Usage(inputTokens: 1, outputTokens: 2), usd: usd)
    }

    @Test func ledgerTotalSince() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ledger = CostLedger(file: file)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try ledger.append(record(t0, usd: 1.0))
        try ledger.append(record(t0.addingTimeInterval(1000), usd: 2.5))
        try ledger.append(record(t0.addingTimeInterval(2000), usd: nil))
        #expect(try ledger.total(since: nil) == 3.5)
        #expect(try ledger.total(since: t0.addingTimeInterval(500)) == 2.5)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
    }

    @Test func missingFileTotalsZero() throws {
        #expect(try CostLedger(file: tempFile()).total(since: nil) == 0)
        #expect(try CostLedger(file: tempFile()).limitUse(since: nil) == nil)
    }

    @Test func limitUseSumsSubscriptionRecordsAndCountsResetWindowsAsZero() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ledger = CostLedger(file: file)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = Usage(inputTokens: 100_000, outputTokens: 10_000)
        try ledger.append(CostRecord(date: t0, lecture: "API", model: "claude-opus-5-5", usage: usage, usd: 0.6))
        try ledger.append(CostRecord(date: t0.addingTimeInterval(1000), lecture: "Sub", model: "claude-opus-5-5", usage: usage, usd: 0,
                                     limitUse: LimitUse(session: 0.04, week: 0.01)))
        try ledger.append(CostRecord(date: t0.addingTimeInterval(2000), lecture: "Sub", model: "claude-haiku-5-5", usage: usage, usd: 0,
                                     limitUse: LimitUse(session: nil, week: 0.02)))
        #expect(try ledger.limitUse(since: nil) == LimitUse(session: 0.04, week: 0.03))
        #expect(try ledger.limitUse(since: t0.addingTimeInterval(1500)) == LimitUse(session: 0, week: 0.02))
        #expect(try ledger.limitUse(since: t0.addingTimeInterval(2500)) == nil)
        #expect(abs(try ledger.total(since: nil) - 0.6) < 1e-9)
    }

    /// Lines written before Faden recorded the limit use still count towards the dollar totals.
    @Test func oldLinesWithoutLimitUseStillDecode() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"date":"2026-10-01T10:00:00Z","lecture":"Old","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2},"usd":1.5}"#
            .appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let ledger = CostLedger(file: file)
        #expect(try ledger.total(since: nil) == 1.5)
        #expect(try ledger.limitUse(since: nil) == nil)
    }

    @Test func aSubscriptionCallRecordsWhatItWouldHaveCostWithAnAPIKey() {
        let call = PaidCall(model: "claude-opus-5-5", usage: Usage(inputTokens: 1_000_000),
                            subscription: SubscriptionLimits(session: 0.1, week: 0.1))
        let r = CostRecord(date: .now, lecture: "L", step: .verify, call: call)
        #expect(r.step == .verify)
        #expect(r.provider == "anthropic")
        #expect(r.billing == .subscription)
        #expect(r.usd == 0)
        #expect(r.apiUSD == 4.0)
    }

    @Test func anAPICallPaysTheAPIPrice() {
        let call = PaidCall(model: "claude-opus-5-5", usage: Usage(inputTokens: 1_000_000))
        let r = CostRecord(date: .now, lecture: "L", step: .notes, call: call)
        #expect(r.billing == .api)
        #expect(r.usd == 4.0)
        #expect(r.apiUSD == 4.0)
    }

    @Test func linesHaveTheirKeysInTheSameOrder() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let call = PaidCall(model: "claude-haiku-5-5", usage: Usage(inputTokens: 5, outputTokens: 7))
        try CostLedger(file: file).append(
            CostRecord(date: Date(timeIntervalSince1970: 1_700_000_000), lecture: "L", step: .notes, call: call))
        let line = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(line.hasPrefix(#"{"apiUSD":"#))
        #expect(line.contains(#""billing":"api","date":"2023-11-14T22:13:20Z","lecture":"L","model":"claude-haiku-5-5","provider":"anthropic","step":"notes","usage":{"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"input_tokens":5,"output_tokens":7},"usd":"#))
    }

    /// Lines written before Faden recorded the API price are priced from their tokens.
    @Test func apiTotalPricesOldLinesFromTheirTokens() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"date":"2026-10-01T10:00:00Z","lecture":"Old","model":"claude-opus-5-5","usage":{"input_tokens":1000000},"usd":0}"#
            .appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let ledger = CostLedger(file: file)
        let call = PaidCall(model: "claude-opus-5-5", usage: Usage(outputTokens: 1_000_000),
                            subscription: SubscriptionLimits(session: 0, week: 0))
        try ledger.append(CostRecord(date: Date(timeIntervalSince1970: 1_800_000_000), lecture: "New", step: .notes, call: call))
        #expect(try ledger.total(since: nil) == 0)
        #expect(try ledger.apiTotal(since: nil) == 24.0)
    }

    @Test func skipsUndecodableLinesAndKeepsContent() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "garbage\n".write(to: file, atomically: true, encoding: .utf8)
        let ledger = CostLedger(file: file)
        try ledger.append(record(Date(timeIntervalSince1970: 1_700_000_000), usd: 4))
        #expect(try ledger.total(since: nil) == 4)
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("garbage\n"))
    }
}
