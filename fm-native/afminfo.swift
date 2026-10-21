// Query the native FoundationModels API directly, instead of inferring model
// properties through the `fm serve` OpenAI shim.
import Foundation
import FoundationModels

let model = SystemLanguageModel.default

print("=== availability ===")
switch model.availability {
case .available:
    print("available: true")
case .unavailable(let reason):
    print("available: false  reason: \(reason)")
@unknown default:
    print("available: unknown")
}

print("\n=== model introspection (Mirror over SystemLanguageModel.default) ===")
let m = Mirror(reflecting: model)
for child in m.children {
    print("  \(child.label ?? "?"): \(child.value)")
}
print("  description: \(String(describing: model))")

// contextSize / supportedLanguages are the two properties third-party guides say to
// read rather than hard-coding a token limit.
print("\n=== languages ===")
print("  supportedLanguages count: \(model.supportedLanguages.count)")

print("\n=== GenerationOptions surface ===")
let opts = GenerationOptions(temperature: 0.0)
print("  GenerationOptions(temperature:0) -> \(opts)")
let capped = GenerationOptions(temperature: 0.0, maximumResponseTokens: 16)
print("  GenerationOptions(maximumResponseTokens:16) -> \(capped)")
