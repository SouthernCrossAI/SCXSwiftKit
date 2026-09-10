import Foundation
import SCXRuntime

// scx-chat [--model ID] [--models] <prompt>
// Streams a chat completion from api.scx.ai. Reasoning is printed dimmed, usage at the end.

var args = Array(CommandLine.arguments.dropFirst())
guard let apiKey = SCXClient.apiKeyFromEnvironment() else {
    FileHandle.standardError.write(Data("Set SCX_API_KEY or put the key in ~/.config/scx/api_key\n".utf8))
    exit(1)
}
let client = SCXClient(apiKey: apiKey)

var model = "MAGPiE"
if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
    model = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

if args.first == "--models" {
    for info in try await client.models() where !info.supportedFeatures.isEmpty {
        print("\(info.id)\tregions=\(info.regions.joined(separator: ","))\tfeatures=\(info.supportedFeatures.joined(separator: ","))\tcontext=\(info.contextLength ?? 0)")
    }
    exit(0)
}

let prompt = args.joined(separator: " ")
guard !prompt.isEmpty else {
    print("usage: scx-chat [--model ID] [--models] <prompt>")
    exit(2)
}

var request = ChatRequest(model: model, messages: [ChatMessage(role: "user", content: prompt)])
request.maxTokens = 1024

let dim = "\u{1B}[2m", reset = "\u{1B}[0m"
var inReasoning = false
do {
    for try await chunk in client.stream(request) {
        for choice in chunk.choices ?? [] {
            if let reasoning = choice.delta.reasoningContent, !reasoning.isEmpty {
                if !inReasoning { print("\(dim)[reasoning] ", terminator: ""); inReasoning = true }
                print(reasoning, terminator: "")
            }
            if let text = choice.delta.content, !text.isEmpty {
                if inReasoning { print(reset); inReasoning = false }
                print(text, terminator: "")
            }
            fflush(stdout)
        }
        if let usage = chunk.usage {
            print("\n\(dim)[usage] model=\(chunk.model ?? model) prompt=\(usage.promptTokens) completion=\(usage.completionTokens) reasoning=\(usage.reasoningTokens)\(reset)")
        }
    }
    print()
} catch {
    FileHandle.standardError.write(Data("\n\(error)\n".utf8))
    exit(1)
}
