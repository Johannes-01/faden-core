// Summarises one or more costs.jsonl ledgers into the cost per lecture run.
// Usage: swift scripts/cost-report.swift [costs.jsonl ...]   (default: this Mac's ledger)
//
// Costs are recomputed from the recorded tokens at API prices, so runs made on the Claude subscription
// (logged as $0) show what they would have cost with an API key. Keep the prices in sync with
// `Pricing` in Sources/FadenCore/Output/CostLedger.swift.
import Foundation

struct Usage: Decodable {
    var input_tokens = 0
    var output_tokens = 0
    var cache_creation_input_tokens = 0
    var cache_read_input_tokens = 0
    var total: Int { input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens }
}

struct Record: Decodable {
    var date: Date
    var lecture: String
    var model: String
    var usage: Usage
}

func usd(model: String, usage u: Usage) -> Double? {
    let input: Double, output: Double, cacheRead: Double, cacheWrite: Double
    switch model {
    case "claude-opus-5-5":
        (input, output, cacheRead, cacheWrite) = (4.00, 20.00, 0.20, 5.00)
    case "claude-haiku-5-5":
        let long = u.input_tokens + u.cache_read_input_tokens + u.cache_creation_input_tokens > 100_000
        input = long ? 0.50 : 0.10
        output = long ? 2.50 : 0.50
        cacheRead = input * 0.10
        cacheWrite = input * 1.25
    default:
        return nil
    }
    let total = Double(u.input_tokens) * input + Double(u.output_tokens) * output
        + Double(u.cache_read_input_tokens) * cacheRead + Double(u.cache_creation_input_tokens) * cacheWrite
    return total / 1_000_000
}

let defaultLedger = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Faden/costs.jsonl")
let files = CommandLine.arguments.count > 1
    ? CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    : [defaultLedger]

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

/// One lecture in one ledger. The same lecture name in two friends' ledgers stays separate.
struct Lecture {
    var file: String
    var name: String
    var runs = 0          // notes calls; "Process again" adds one
    var inputTokens = 0   // all prompt tokens, cached or not
    var outputTokens = 0
    var usd = 0.0
}

var lectures: [String: Lecture] = [:]
var order: [String] = []
var skippedEmpty = 0
var unknownModels: Set<String> = []

for file in files {
    guard let data = try? Data(contentsOf: file) else {
        FileHandle.standardError.write(Data("cannot read \(file.path)\n".utf8))
        exit(1)
    }
    for line in data.split(separator: 0x0A) {
        guard let r = try? decoder.decode(Record.self, from: Data(line)) else { continue }
        // Older subscription runs were logged before token usage was recorded.
        guard r.usage.total > 0 else { skippedEmpty += 1; continue }
        guard let cost = usd(model: r.model, usage: r.usage) else { unknownModels.insert(r.model); continue }
        let key = file.path + "\u{0}" + r.lecture
        if lectures[key] == nil {
            lectures[key] = Lecture(file: file.lastPathComponent, name: r.lecture)
            order.append(key)
        }
        if r.model == "claude-opus-5-5" { lectures[key]!.runs += 1 }
        lectures[key]!.inputTokens += r.usage.input_tokens + r.usage.cache_read_input_tokens
            + r.usage.cache_creation_input_tokens
        lectures[key]!.outputTokens += r.usage.output_tokens
        lectures[key]!.usd += cost
    }
}

func money(_ v: Double) -> String { String(format: "$%.2f", v) }
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
}
func lpad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }

guard !order.isEmpty else {
    print("No runs with token data.")
    if skippedEmpty > 0 { print("Skipped \(skippedEmpty) entries without token data.") }
    exit(0)
}

let showFile = files.count > 1
print((showFile ? pad("File", 18) : "") + pad("Lecture", 44) + lpad("Runs", 5) + lpad("In tok", 10)
    + lpad("Out tok", 9) + lpad("Cost", 9) + lpad("Per run", 9))
var perRun: [Double] = []
for key in order {
    let l = lectures[key]!
    let runs = max(l.runs, 1)
    for _ in 0..<runs { perRun.append(l.usd / Double(runs)) }
    print((showFile ? pad(l.file, 18) : "") + pad(l.name, 44) + lpad("\(l.runs)", 5) + lpad("\(l.inputTokens)", 10)
        + lpad("\(l.outputTokens)", 9) + lpad(money(l.usd), 9) + lpad(money(l.usd / Double(runs)), 9))
}

let sorted = perRun.sorted()
let median = sorted.count % 2 == 1
    ? sorted[sorted.count / 2]
    : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
let total = lectures.values.reduce(0) { $0 + $1.usd }
print("")
print("Lectures: \(lectures.count)   Runs: \(perRun.count)   Total: \(money(total))")
print("Per run: median \(money(median)), mean \(money(total / Double(perRun.count))), "
    + "min \(money(sorted.first!)), max \(money(sorted.last!))")
if skippedEmpty > 0 { print("Skipped \(skippedEmpty) entries without token data.") }
if !unknownModels.isEmpty { print("Skipped unknown models: \(unknownModels.sorted().joined(separator: ", "))") }
