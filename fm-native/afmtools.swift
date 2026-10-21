// Does the on-device model actually do tool calling? `GenerationOptions` exposes
// `toolCallingMode`, but `fm serve` never surfaces it. Tool use is the one capability
// that decides whether a 3B local model can act as a router rather than a classifier.
import Foundation
import FoundationModels

struct WeatherTool: Tool {
    let name = "getWeather"
    let description = "Get the current temperature in celsius for a named city."

    @Generable
    struct Arguments {
        @Guide(description: "The city name, e.g. Pune")
        var city: String
    }

    // Record what the model asked for, so we can verify it extracted the argument.
    static let calls = CallBox()
    final class CallBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _cities: [String] = []
        var cities: [String] { lock.lock(); defer { lock.unlock() }; return _cities }
        func add(_ c: String) { lock.lock(); _cities.append(c); lock.unlock() }
    }

    func call(arguments: Arguments) async throws -> String {
        WeatherTool.calls.add(arguments.city)
        return "The current temperature in \(arguments.city) is 31 celsius."
    }
}

let model = SystemLanguageModel.default
let tool = WeatherTool()

print("=== tool calling (native) ===")
let cases = [
    ("direct", "What is the temperature in Pune right now?"),
    ("indirect", "I am packing for a trip to Reykjavik today. Should I bring a coat? Check the weather first."),
    ("no_tool_needed", "What is 12 plus 30? Reply with only the number."),
]

for (id, prompt) in cases {
    let session = LanguageModelSession(model: model, tools: [tool])
    let before = WeatherTool.calls.cities.count
    do {
        let t0 = Date()
        let resp = try await session.respond(to: prompt,
                                             options: GenerationOptions(temperature: 0.0))
        let elapsed = Date().timeIntervalSince(t0)
        let called = WeatherTool.calls.cities.count - before
        let cities = WeatherTool.calls.cities.suffix(called)
        let text = resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
        print("  [\(id)] tool_calls=\(called) args=\(Array(cities)) "
              + String(format: "%.2fs", elapsed))
        print("    -> \(String(text.prefix(140)).replacingOccurrences(of: "\n", with: " "))")
    } catch {
        print("  [\(id)] ERROR \(error)")
    }
}

// Structured output via @Generable, the native equivalent of response_format.
@Generable
struct Ticket {
    @Guide(description: "One of BILLING, TECHNICAL, or SALES")
    var category: String
    @Guide(description: "Urgency from 1 to 5")
    var urgency: Int
    @Guide(description: "Two short keyword tags")
    var tags: [String]
}

print("\n=== @Generable structured output (native) ===")
let tickets = [
    "I was charged twice for my subscription this month and need a refund urgently.",
    "The app crashes every time I open the settings page.",
    "Do you offer volume discounts for a 200-seat licence?",
]
for t in tickets {
    let session = LanguageModelSession(model: model)
    do {
        let resp = try await session.respond(to: "Classify this support ticket: \(t)",
                                             generating: Ticket.self,
                                             options: GenerationOptions(temperature: 0.0))
        let v = resp.content
        print("  category=\(v.category) urgency=\(v.urgency) tags=\(v.tags)")
    } catch {
        print("  ERROR \(error)")
    }
}
