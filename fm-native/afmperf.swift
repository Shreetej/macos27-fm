// Native streaming latency, to separate the model's cost from the `fm serve` shim's.
// Mirrors fmprobe.py's curve: same prompt sizes, same shape of measurement.
import Foundation
import FoundationModels

func jsonLine(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d)
    print("JSON " + String(data: data, encoding: .utf8)!)
}

// Same deterministic filler as bench.py / fmprobe.py so prompts are comparable.
let TOPICS = ["unified memory", "KV cache", "quantization", "Metal kernels",
              "speculative decoding", "mixture of experts", "prefix caching",
              "thermal throttling", "tokenizers", "continuous batching"]

func filler(_ approxTokens: Int) -> String {
    var out = ""
    var i = 0
    // deterministic: index-driven, not random, so repeated runs are identical
    while out.count < approxTokens * 4 {
        i += 1
        let a = TOPICS[(i * 3) % TOPICS.count]
        let b = TOPICS[(i * 7 + 1) % TOPICS.count]
        out += "Note \(i): measurement \((i &* 37) % 9000) shows \(a) interacting with \(b) "
        out += "in configuration \(["A","B","C","D","E","F","G","H"][i % 8])\(i % 99 + 1), "
        out += "variance \(String(format: "%.3f", Double((i &* 13) % 1000) / 1000.0)). "
    }
    return out
}

let model = SystemLanguageModel.default
let sizes = [128, 512, 2048, 4096]
let reps = 3

print("=== native streaming latency (temperature 0, maximumResponseTokens 128) ===")
print("  n      rep   ttft_s    e2e_s     chars")

for n in sizes {
    let prompt = filler(n) + "\n\nSummarise the notes above in one paragraph."
    var ttfts: [Double] = []
    var decs: [Double] = []
    // one discarded warmup per size, matching fmprobe.py
    for rep in 0...reps {
        let session = LanguageModelSession(model: model)
        let opts = GenerationOptions(temperature: 0.0, maximumResponseTokens: 128)
        let t0 = Date()
        var tFirst: Date? = nil
        var chars = 0
        do {
            let stream = session.streamResponse(to: prompt, options: opts)
            for try await partial in stream {
                if tFirst == nil { tFirst = Date() }
                chars = partial.content.count
            }
        } catch {
            print("  n=\(n) rep=\(rep) ERROR \(error)")
            continue
        }
        let tEnd = Date()
        guard let tf = tFirst else { continue }
        let ttft = tf.timeIntervalSince(t0)
        let e2e = tEnd.timeIntervalSince(t0)
        let gen = tEnd.timeIntervalSince(tf)
        // chars/5.6 approximates tokens for this model (measured: 1422 chars at 256 cap)
        let approxTok = Double(chars) / 5.6
        let dec = gen > 0.05 ? approxTok / gen : 0
        if rep > 0 {   // skip warmup
            ttfts.append(ttft)
            decs.append(dec)
            jsonLine(["test": "native_curve", "n": n, "rep": rep, "ttft_s": ttft,
                      "e2e_s": e2e, "chars": chars, "approx_decode_tps": dec])
        }
        let tag = rep == 0 ? "  (warmup, discarded)" : ""
        print("  \(n)\t\(rep)\t" + String(format: "%.3f", ttft) + "\t"
              + String(format: "%.3f", e2e) + "\t\(chars)" + tag)
        // match fmprobe.py's 1s cooldown
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    let medTtft = ttfts.sorted()[ttfts.count / 2]
    let medDec = decs.sorted()[decs.count / 2]
    print("  -> n=\(n) median ttft " + String(format: "%.3f", medTtft)
          + "s, approx decode " + String(format: "%.1f", medDec) + " tok/s")
}
