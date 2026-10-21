// Native FoundationModels test: does maximumResponseTokens work, what is contextSize,
// and what is output quality like when driven through the real API rather than the
// `fm serve` OpenAI shim?
import Foundation
import FoundationModels

func jsonLine(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d)
    print("JSON " + String(data: data, encoding: .utf8)!)
}

let model = SystemLanguageModel.default

// ---- contextSize -------------------------------------------------------------
print("=== contextSize ===")
print("  model.contextSize = \(model.contextSize)")

// ---- maximumResponseTokens: the thing fm serve drops -------------------------
print("\n=== maximumResponseTokens (native) ===")
let notes = (1...120).map { "Note \($0): measurement \($0 * 37 % 9000) shows KV cache interacting with quantization." }.joined(separator: " ")
let longAsk = notes + "\n\nUsing the notes above, write a long, detailed technical report with numbered sections. Do not stop early."

for cap in [16, 64, 256] {
    let session = LanguageModelSession(model: model)
    let opts = GenerationOptions(temperature: 0.0, maximumResponseTokens: cap)
    let t0 = Date()
    do {
        let resp = try await session.respond(to: longAsk, options: opts)
        let elapsed = Date().timeIntervalSince(t0)
        // approximate token count via the session transcript entry count is unreliable;
        // report characters and let fm count-tokens do the counting afterwards
        let text = resp.content
        jsonLine(["test": "maxtokens", "cap": cap, "chars": text.count,
                  "elapsed_s": elapsed, "head": String(text.prefix(120))])
        print("  cap=\(cap): \(text.count) chars in \(String(format: "%.2f", elapsed))s")
    } catch {
        print("  cap=\(cap): ERROR \(error)")
        jsonLine(["test": "maxtokens", "cap": cap, "error": "\(error)"])
    }
}

// ---- quality probes ----------------------------------------------------------
// Deterministic, checkable tasks. Not a leaderboard: a smoke test of whether the 3B
// model is actually usable for router-shaped work.
struct Probe { let id: String; let prompt: String; let expect: (String) -> Bool }

let probes: [Probe] = [
    Probe(id: "arith", prompt: "What is 17 * 24? Reply with only the number.",
          expect: { $0.contains("408") }),
    Probe(id: "classify_billing",
          prompt: "Classify this support ticket into exactly one of: BILLING, TECHNICAL, SALES. Reply with only the label.\nTicket: 'I was charged twice for my subscription this month.'",
          expect: { $0.uppercased().contains("BILLING") }),
    Probe(id: "classify_technical",
          prompt: "Classify this support ticket into exactly one of: BILLING, TECHNICAL, SALES. Reply with only the label.\nTicket: 'The app crashes every time I open the settings page.'",
          expect: { $0.uppercased().contains("TECHNICAL") }),
    Probe(id: "extract",
          prompt: "Extract the year. Reply with only the 4-digit year.\nText: 'The Swift language was introduced at WWDC in 2014.'",
          expect: { $0.contains("2014") }),
    Probe(id: "negation",
          prompt: "Answer yes or no only. Is the following statement true? 'A square has five sides.'",
          expect: { $0.lowercased().contains("no") }),
    Probe(id: "instruct_format",
          prompt: "Reply with exactly three words, no punctuation: name three primary colors.",
          expect: { $0.split(whereSeparator: { $0 == " " || $0 == "\n" }).count == 3 }),
    Probe(id: "refusal_check",
          prompt: "Summarize this in one sentence: 'Memory bandwidth limits how fast a GPU can feed its compute units.'",
          expect: { !$0.lowercased().contains("i cannot") && $0.count > 20 }),
]

print("\n=== quality probes (native API, temperature 0) ===")
var passes = 0
for p in probes {
    let session = LanguageModelSession(model: model)
    let opts = GenerationOptions(temperature: 0.0)
    do {
        let t0 = Date()
        let resp = try await session.respond(to: p.prompt, options: opts)
        let elapsed = Date().timeIntervalSince(t0)
        let text = resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = p.expect(text)
        if ok { passes += 1 }
        jsonLine(["test": "quality", "id": p.id, "pass": ok, "elapsed_s": elapsed,
                  "answer": String(text.prefix(200))])
        print("  \(ok ? "PASS" : "FAIL") \(p.id): \(String(text.prefix(90)).replacingOccurrences(of: "\n", with: " "))")
    } catch {
        jsonLine(["test": "quality", "id": p.id, "pass": false, "error": "\(error)"])
        print("  ERROR \(p.id): \(error)")
    }
}
print("  passed \(passes)/\(probes.count)")
