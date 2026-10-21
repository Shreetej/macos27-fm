# Native FoundationModels probes

The `fm serve` OpenAI shim drops capabilities the framework has. These Swift programs
query the native API directly, which is the only way to answer "which model is this"
and "does max_tokens work" authoritatively.

Build and run (macOS 27, Swift 6.4, no Xcode project needed):

    swiftc -O afminfo.swift  -o afminfo  && ./afminfo    # model identity, options surface
    swiftc -O afmtest.swift  -o afmtest  && ./afmtest    # contextSize, maximumResponseTokens, quality
    swiftc -O afmperf.swift  -o afmperf  && ./afmperf    # native streaming latency vs prompt length
    swiftc -O afmtools.swift -o afmtools && ./afmtools   # tool calling + @Generable structured output

Outputs are captured in ../fmprobe-out/native-*.txt.
