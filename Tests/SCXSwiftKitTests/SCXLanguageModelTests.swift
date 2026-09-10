// The provider compiles out on pre-27 toolchains (see SCXLanguageModel.swift); so do its tests,
// otherwise `swift test` on Xcode 26 fails to build this target even when filtered out.
#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import SCXRuntime
import Testing
@testable import SCXSwiftKit

/// Live tests run only when a key is present, so CI without the secret skips them instead of failing.
private let liveKeyAvailable = SCXClient.apiKeyFromEnvironment() != nil
private let live: ConditionTrait = .enabled(if: liveKeyAvailable, "Needs SCX_API_KEY or ~/.config/scx/api_key")

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private func liveKey() throws -> String {
    try #require(SCXClient.apiKeyFromEnvironment(), "No SCX API key: set SCX_API_KEY or create ~/.config/scx/api_key")
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func mapsTranscriptAndOptionsToChatRequest() throws {
    let transcript = Transcript(entries: [
        .instructions(.init(id: "i", segments: [.text(.init(id: "s", content: "Be brief."))], toolDefinitions: [])),
        .prompt(.init(id: "p", segments: [.text(.init(id: "t", content: "Weather in Sydney?"))], options: .init(), responseFormat: nil)),
        .toolCalls(.init(id: "c", [Transcript.ToolCall(id: "call_1", toolName: "getWeather", arguments: try GeneratedContent(json: #"{"city":"Sydney"}"#))])),
        .toolOutput(.init(id: "call_1", toolName: "getWeather", segments: [.text(.init(id: "o", content: "22C, sunny"))])),
    ])
    let request = LanguageModelExecutorGenerationRequest(
        id: UUID(), transcript: transcript, enabledTools: [],
        generationOptions: .init(temperature: 1.5),
        contextOptions: .init(reasoningLevel: .deep), metadata: [:])

    let chat = try SCXExecutor.chatRequest(from: request, model: "MAGPiE")

    #expect(chat.messages.map(\.role) == ["system", "user", "assistant", "tool"])
    #expect(chat.messages[2].toolCalls?.first?.function.name == "getWeather")
    #expect(chat.messages[2].toolCalls?.first?.function.arguments.contains("Sydney") == true)
    #expect(chat.messages[3].toolCallID == "call_1")
    #expect(chat.temperature == 1) // clamped to SCX's 0...1 range
    #expect(chat.reasoningEffort == "high")
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func mapsSamplingModesToRequestParameters() throws {
    let transcript = Transcript(entries: [
        .prompt(.init(id: "p", segments: [.text(.init(id: "t", content: "hi"))], options: .init(), responseFormat: nil)),
    ])
    func chat(_ options: GenerationOptions) throws -> ChatRequest {
        try SCXExecutor.chatRequest(
            from: .init(id: UUID(), transcript: transcript, enabledTools: [],
                        generationOptions: options, contextOptions: .init(), metadata: [:]),
            model: "MAGPiE")
    }
    #expect(try chat(.init(samplingMode: .greedy)).temperature == 0)
    let topK = try chat(.init(samplingMode: .random(top: 40, seed: 7)))
    #expect(topK.topK == 40)
    #expect(topK.seed == 7)
    let topP = try chat(.init(samplingMode: .random(probabilityThreshold: 0.9)))
    #expect(topP.topP == 0.9)
    #expect(topP.seed == nil)
}

/// `load` must reject the image, video, audio, embedding and moderation entries that share
/// SCX's `/v1/models` catalogue with the chat models. Fixtures are trimmed real catalogue rows.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func loadRejectsModelsThatDoNotGenerateText() throws {
    func info(_ json: String) throws -> ModelInfo {
        try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
    }
    let chat = try info(#"{"id":"MAGPiE","input_modalities":["text"],"output_modalities":["text"],"max_output_length":131072,"supported_features":["tools","reasoning","json_mode"]}"#)
    let image = try info(#"{"id":"seedream-5.0","input_modalities":["text","image"],"output_modalities":["image"],"max_output_length":null,"supported_features":["image-generation","image-editing"]}"#)
    let speech = try info(#"{"id":"Whisper-Large-v3","input_modalities":["audio"],"output_modalities":["text"],"max_output_length":4096,"supported_features":[]}"#)
    let moderation = try info(#"{"id":"opir-large","input_modalities":["text"],"output_modalities":["text"],"max_output_length":null,"supported_features":["moderation"]}"#)
    // A future chat model with no features listed must still load; the package promises that.
    let future = try info(#"{"id":"future","input_modalities":["text"],"output_modalities":["text"],"max_output_length":4096,"supported_features":[]}"#)

    try SCXLanguageModel.requireTextGeneration(chat)
    try SCXLanguageModel.requireTextGeneration(future)
    for rejected in [image, speech, moderation] {
        #expect(throws: SCXError.self) { try SCXLanguageModel.requireTextGeneration(rejected) }
    }
}

/// Live check against api.scx.ai. Needs an API key (SCX_API_KEY or ~/.config/scx/api_key) and credit on the account.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func streamsAnAnswerThroughLanguageModelSession() async throws {
    let apiKey = try liveKey()
    let model = try await SCXLanguageModel.load(model: "MAGPiE", apiKey: apiKey)
    #expect(model.capabilities.contains(.toolCalling))

    let session = LanguageModelSession(model: model)
    let response = try await session.respond(to: "In one short sentence, what is the capital of Australia?")
    print("MAGPiE:", response.content)
    #expect(response.content.localizedCaseInsensitiveContains("Canberra"))
}

@Generable
struct Regulator {
    let name: String
    let acronym: String
    let supervises: [String]
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func guidedGenerationReturnsSchemaValidContent() async throws {
    let apiKey = try liveKey()
    let session = LanguageModelSession(model: SCXLanguageModel(model: "MAGPiE", apiKey: apiKey))
    let response = try await session.respond(to: "Which Australian regulator supervises banks?", generating: Regulator.self)
    print("Regulator:", response.content)
    #expect(response.content.acronym.uppercased().contains("APRA"))
    #expect(!response.content.supervises.isEmpty)
}

struct WeatherTool: Tool {
    let name = "getWeather"
    let description = "Current weather for a city"

    @Generable
    struct Arguments {
        let city: String
    }

    func call(arguments: Arguments) async throws -> String {
        "\(arguments.city): 22°C and sunny"
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func multiTurnHistoryIsReplayed() async throws {
    let apiKey = try liveKey()
    let session = LanguageModelSession(model: SCXLanguageModel(model: "MAGPiE", apiKey: apiKey))
    _ = try await session.respond(to: "My name is Bruce and I live in Perth. Just say hello.")
    let second = try await session.respond(to: "What is my name? One word.")
    print("Second turn:", second.content)
    #expect(second.content.localizedCaseInsensitiveContains("Bruce"))
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func loadedThirdPartyModelResolvesAndAnswers() async throws {
    let apiKey = try liveKey()
    let model = try await SCXLanguageModel.load(model: "GLM-5.2", apiKey: apiKey)
    #expect(model.capabilities.contains(.reasoning))
    // No token cap: SCX counts reasoning against max_tokens, so a cap can return empty content.
    let response = try await LanguageModelSession(model: model)
        .respond(to: "In one short sentence, what does Swift's `defer` do?")
    print("GLM-5.2:", response.content)
    #expect(!response.content.isEmpty)
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func structuredOutputStreamsPartialSnapshots() async throws {
    let apiKey = try liveKey()
    let session = LanguageModelSession(model: SCXLanguageModel(model: "MAGPiE", apiKey: apiKey))
    var snapshots = 0
    var lastAcronym: String?
    for try await snapshot in session.streamResponse(to: "Which Australian regulator supervises banks?", generating: Regulator.self) {
        snapshots += 1
        lastAcronym = snapshot.content.acronym
    }
    print("Snapshots:", snapshots, "acronym:", lastAcronym ?? "nil")
    #expect(snapshots > 1)
    #expect(lastAcronym?.uppercased().contains("APRA") == true)
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func oversizedPromptThrowsContextSizeExceeded() async throws {
    let apiKey = try liveKey()
    let session = LanguageModelSession(model: SCXLanguageModel(model: "MAGPiE", apiKey: apiKey))
    let oversized = String(repeating: "word ", count: 160_000) // ~200k tokens against a 131k context
    do {
        _ = try await session.respond(to: oversized)
        Issue.record("Expected a context size error")
    } catch {
        let description = String(describing: error)
        #expect(description.localizedCaseInsensitiveContains("too long")
            || description.localizedCaseInsensitiveContains("exceededContextWindowSize")
            || description.localizedCaseInsensitiveContains("contextSize"))
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func toolCallingRoundTrip() async throws {
    let apiKey = try liveKey()
    let session = LanguageModelSession(model: SCXLanguageModel(model: "MAGPiE", apiKey: apiKey), tools: [WeatherTool()])
    let response = try await session.respond(to: "Use the getWeather tool for Sydney and tell me the temperature.")
    print("Tool answer:", response.content)
    #expect(response.content.contains("22"))
    let calledTool = session.transcript.contains { entry in
        if case .toolCalls = entry { return true }
        return false
    }
    #expect(calledTool)
}
#endif  // canImport(FoundationModels, _version: 2)
