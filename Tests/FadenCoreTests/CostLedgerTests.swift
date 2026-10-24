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
        #expect(try CostLedger(file: tempFile()).apiTotal(since: nil) == 0)
    }

    @Test func apiTotalPricesSubscriptionRunsFromTokens() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ledger = CostLedger(file: file)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = Usage(inputTokens: 100_000, outputTokens: 10_000)  // $0.40 + $0.20 on Opus
        try ledger.append(CostRecord(date: t0, lecture: "API", model: "claude-opus-5-5", usage: usage, usd: 0.6))
        try ledger.append(CostRecord(date: t0.addingTimeInterval(1000), lecture: "Sub", model: "claude-opus-5-5", usage: usage, usd: 0))
        try ledger.append(CostRecord(date: t0.addingTimeInterval(2000), lecture: "Old", model: "claude-opus-5-5", usage: Usage(), usd: 0))
        try ledger.append(CostRecord(date: t0.addingTimeInterval(3000), lecture: "?", model: "gpt-x", usage: usage, usd: nil))
        #expect(abs(try ledger.total(since: nil) - 0.6) < 1e-9)
        #expect(abs(try ledger.apiTotal(since: nil) - 1.2) < 1e-9)
        #expect(abs(try ledger.apiTotal(since: t0.addingTimeInterval(500)) - 0.6) < 1e-9)
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
