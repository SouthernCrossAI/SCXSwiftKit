// The provider compiles out on pre-27 toolchains (see SCXLanguageModel.swift); so do its tests,
// otherwise `swift test` on Xcode 26 fails to build this target even when filtered out.
#if canImport(FoundationModels, _version: 2)
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import SCXRuntime
import Testing
import UniformTypeIdentifiers
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

    let chat = try SCXExecutor.chatRequest(from: request, model: SCXLanguageModel(model: "MAGPiE", apiKey: "test"))

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
            model: SCXLanguageModel(model: "MAGPiE", apiKey: "test"))
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
    let decision = try info(#"{"id":"apex","input_modalities":["text","image"],"output_modalities":["text"],"max_output_length":null,"supported_features":["systemone"]}"#)
    // A future chat model with no features listed must still load; the package promises that.
    let future = try info(#"{"id":"future","input_modalities":["text"],"output_modalities":["text"],"max_output_length":4096,"supported_features":[]}"#)

    try SCXLanguageModel.requireTextGeneration(chat)
    try SCXLanguageModel.requireTextGeneration(future)
    for rejected in [image, speech, moderation, decision] {
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
    let model = try await SCXLanguageModel.load(model: "GLM-5.3", apiKey: apiKey)
    #expect(model.capabilities.contains(.reasoning))
    // No token cap: SCX counts reasoning against max_tokens, so a cap can return empty content.
    let response = try await LanguageModelSession(model: model)
        .respond(to: "In one short sentence, what does Swift's `defer` do?")
    print("GLM-5.3:", response.content)
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
    } catch let error as LanguageModelError {
        // Match the case, not the wording. SCX rewords this message from time to time and the
        // provider text reaches the error only as its debug description.
        guard case .contextSizeExceeded = error else {
            Issue.record("Expected contextSizeExceeded, got \(error)")
            return
        }
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
// MARK: Images and video

/// `colors` are laid out left to right in equal columns.
private func image(_ colors: [CGColor], width: Int = 64, height: Int = 32, opaque: Bool = true) -> CGImage {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    for (index, color) in colors.enumerated() {
        let column = width / colors.count
        context.setFillColor(color)
        context.fill(CGRect(x: index * column, y: 0, width: column, height: height))
    }
    return context.makeImage()!
}

private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

/// A one second, 64x64, solid red H.264 MP4.
private let redClip = Data(base64Encoded: "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAN2bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAqB0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAQAAABAAAAAAIYbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAKABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABw21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYNzdGJsAAAAv3N0c2QAAAAAAAAAAQAAAK9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANWF2Y0MBZAAK/+EAGGdkAAqs2UQmwEQAAAMABAAAAwAoPEiWWAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAYeAAAAAAAAAAYc3R0cwAAAAAAAAABAAAABQAACAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAADhjdHRzAAAAAAAAAAUAAAABAAAQAAAAAAEAACgAAAAAAQAAEAAAAAABAAAAAAAAAAEAAAgAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAFAAAAAQAAAChzdHN6AAAAAAAAAAAAAAAFAAAC3QAAAA4AAAAMAAAADAAAAAwAAAAUc3RjbwAAAAAAAAABAAADpgAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAyAAAACGZyZWUAAAMXbWRhdAAAAq0GBf//qdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0yIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj01IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAKGWIhAAS//7oyfzLKy/j1DezRimzSaccwj0dI/65B2ZLyCHBWQeLicEAAAAKQZokbEP//qmdNAAAAAhBnkJ4gh8CxwAAAAgBnmF0Q/8ExAAAAAgBnmNqQ/8ExQ==")!

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private func prompt(_ segments: [Transcript.Segment]) -> Transcript.Entry {
    .prompt(.init(id: "p", segments: segments, options: .init(), responseFormat: nil))
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private func attachment(_ content: Transcript.Attachment) -> Transcript.Segment {
    .attachment(.init(content: content))
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private func request(_ entries: [Transcript.Entry]) -> LanguageModelExecutorGenerationRequest {
    .init(id: UUID(), transcript: Transcript(entries: entries), enabledTools: [],
          generationOptions: .init(), contextOptions: .init(), metadata: [:])
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private func visionModel(_ limit: Int = 20_000_000) -> SCXLanguageModel {
    var model = SCXLanguageModel(model: "vision", apiKey: "test", capabilities: LanguageModelCapabilities([.vision]))
    model.maximumImageBytes = limit
    return model
}

/// The first attachment of the first message.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private func encodedAttachment(_ chat: ChatRequest) throws -> (data: Data, mediaType: String) {
    for part in chat.messages.first?.parts ?? [] {
        if case .image(let data, let mediaType) = part { return (data, mediaType) }
        if case .video(let data, let mediaType) = part { return (data, mediaType) }
    }
    throw SCXError(status: 0, message: "no attachment in the request")
}

private func rgb(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func promptWithImageBecomesTextAndJPEGParts() throws {
    let chat = try SCXExecutor.chatRequest(from: request([prompt([
        .text(.init(id: "t", content: "What is this?")),
        attachment(.image(.init(image([red])))),
    ])]), model: visionModel())

    let parts = try #require(chat.messages.first?.parts)
    #expect(parts.count == 2)
    guard case .text("What is this?") = parts[0] else { Issue.record("Expected the text first"); return }
    #expect(try encodedAttachment(chat).mediaType == "image/jpeg")
    #expect(chat.messages.first?.content == nil)
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func imageWithTransparencyIsSentAsPNG() throws {
    let chat = try SCXExecutor.chatRequest(from: request([prompt([
        attachment(.image(.init(image([red], opaque: false)))),
    ])]), model: visionModel())
    #expect(try encodedAttachment(chat).mediaType == "image/png")
}

/// Stored left half red, right half blue. `.right` means the stored left edge is the top on screen.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func imageOrientationIsAppliedToThePixels() throws {
    let chat = try SCXExecutor.chatRequest(from: request([prompt([
        attachment(.image(.init(image([red, blue]), orientation: .right))),
    ])]), model: visionModel())

    let source = try #require(CGImageSourceCreateWithData(try encodedAttachment(chat).data as CFData, nil))
    let sent = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(sent.width == 32 && sent.height == 64)
    let top = rgb(of: sent, x: 16, y: 8), bottom = rgb(of: sent, x: 16, y: 56)
    #expect(top.r > 200 && top.b < 60, "top is \(top)")
    #expect(bottom.b > 200 && bottom.r < 60, "bottom is \(bottom)")
}

/// iPhone photos are stored sideways with an EXIF tag, and `Attachment(imageURL:)` reports it.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func imageFileWithEXIFRotationIsSentUpright() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(file, image([red, blue]), [kCGImagePropertyOrientation: 6] as CFDictionary) // 6 is .right
    #expect(CGImageDestinationFinalize(file))

    let chat = try SCXExecutor.chatRequest(from: request([prompt([
        attachment(.image(.init(imageURL: url))),
    ])]), model: visionModel())

    let source = try #require(CGImageSourceCreateWithData(try encodedAttachment(chat).data as CFData, nil))
    let sent = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(sent.width == 32 && sent.height == 64)
    let top = rgb(of: sent, x: 16, y: 8)
    #expect(top.r > 200 && top.b < 60, "top is \(top)")
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func attachmentOverTheLimitIsRefusedBeforeSending() throws {
    do {
        _ = try SCXExecutor.chatRequest(from: request([prompt([attachment(.image(.init(image([red]))))])]), model: visionModel(10))
        Issue.record("Expected a size error")
    } catch LanguageModelError.unsupportedTranscriptContent(let details) {
        #expect(details.debugDescription.contains("limit"))
        #expect(details.unsupportedContent.count == 1)
    }
    var tightVideo = visionModel()
    tightVideo.maximumVideoBytes = 10
    _ = try SCXExecutor.chatRequest(from: request([prompt([attachment(.image(.init(image([red]))))])]), model: tightVideo)
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func imageOnAModelWithoutVisionIsRefused() throws {
    do {
        _ = try SCXExecutor.chatRequest(from: request([prompt([attachment(.image(.init(image([red]))))])]),
                                        model: SCXLanguageModel(model: "MAGPiE", apiKey: "test"))
        Issue.record("Expected a capability error")
    } catch LanguageModelError.unsupportedCapability(let details) {
        #expect(details.capability == .vision)
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func attachmentOutsideAPromptIsRefused() throws {
    let instructions = Transcript.Entry.instructions(.init(
        id: "i", segments: [attachment(.image(.init(image([red]))))], toolDefinitions: []))
    #expect(throws: LanguageModelError.self) {
        try SCXExecutor.chatRequest(from: request([instructions]), model: visionModel())
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func temporaryFailuresCanBeRetried() {
    for status in [429, 503, 529] {
        #expect(SCXExecutor.isTemporary(SCXError(status: status, message: "later")))
    }
    #expect(!SCXExecutor.isTemporary(SCXError(status: 500, message: "broken")))
}

/// Fixtures are the errors SCX returned for oversized files on gemma-4-31B-it.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test func unclearRefusalsOfAttachmentsBecomeAPlainError() throws {
    let withVideo = ChatRequest(model: "gemma-4-31B-it", messages: [
        ChatMessage(role: "user", parts: [.video(Data(count: 1_050_000), mediaType: "video/mp4")]),
    ])
    let textOnly = ChatRequest(model: "gemma-4-31B-it", messages: [ChatMessage(role: "user", content: "hi")])
    let unclear = SCXError(status: 400, type: "invalid_request_error", message: "The request was rejected as invalid.")

    #expect(SCXExecutor.isAttachmentRefusal(unclear, of: withVideo))
    #expect(SCXExecutor.isAttachmentRefusal(SCXError(status: 413, message: "too large"), of: withVideo))
    #expect(!SCXExecutor.isAttachmentRefusal(unclear, of: textOnly))
    #expect(!SCXExecutor.isAttachmentRefusal(SCXError(status: 400, message: "too long", param: "messages"), of: withVideo))
    #expect(!SCXExecutor.isAttachmentRefusal(SCXError(status: 400, message: "bad", param: "temperature"), of: withVideo))
    #expect(!SCXExecutor.isAttachmentRefusal(SCXError(status: 401, message: "bad key"), of: withVideo))

    let error = SCXExecutor.attachmentRefused(unclear, chat: withVideo, transcript: Transcript(entries: []))
    guard case .unsupportedTranscriptContent(let details) = error else { Issue.record("Wrong case: \(error)"); return }
    #expect(details.debugDescription.contains("MB"))
    #expect(details.debugDescription.contains("gemma-4-31B-it"))
    #expect(details.debugDescription.contains("rejected as invalid"))
}

#if canImport(FoundationModels, _version: 2.1) // Data attachments arrived in the 27.2 SDK.
@available(iOS 27.2, macOS 27.2, visionOS 27.2, *)
@Test func dataAttachmentBecomesAVideoPart() throws {
    let chat = try SCXExecutor.chatRequest(from: request([prompt([
        attachment(.data(SCXVideo(mp4: redClip).transcriptRepresentation)),
    ])]), model: visionModel())
    guard case .video(let data, let mediaType)? = chat.messages.first?.parts?.first else {
        Issue.record("Expected a video part")
        return
    }
    #expect(mediaType == "video/mp4")
    #expect(data == redClip)
}

@available(iOS 27.2, macOS 27.2, visionOS 27.2, *)
@Test func onlyModelsWithVideoAcceptMP4() async throws {
    var model = visionModel()
    #expect(try await !model.supportsDataAttachmentType(.mpeg4Movie))
    model.acceptsVideo = true
    #expect(try await model.supportsDataAttachmentType(.mpeg4Movie))
    #expect(try await !model.supportsDataAttachmentType(.pdf))
}

/// SCX takes 300 KB of video for now, much less than the 20 MB for images.
@available(iOS 27.2, macOS 27.2, visionOS 27.2, *)
@Test func videoOverItsOwnLimitIsRefusedBeforeSending() throws {
    let video = { (bytes: Int) in request([prompt([attachment(.data(SCXVideo(mp4: Data(count: bytes)).transcriptRepresentation))])]) }
    _ = try SCXExecutor.chatRequest(from: video(300_000), model: visionModel())
    do {
        _ = try SCXExecutor.chatRequest(from: video(300_001), model: visionModel())
        Issue.record("Expected a size error")
    } catch LanguageModelError.unsupportedTranscriptContent(let details) {
        #expect(details.debugDescription.contains("limit"))
    }
}
#endif

/// Every vision model SCX lists today that `load` accepts, so a new one is covered with no change here.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func everyVisionModelSeesAnImage() async throws {
    let apiKey = try liveKey()
    let vision = try await SCXClient(apiKey: apiKey).models()
        .filter { $0.inputModalities.contains("image") && (try? SCXLanguageModel.requireTextGeneration($0)) != nil }
    #expect(!vision.isEmpty)
    await withTaskGroup(of: Void.self) { group in
        for info in vision {
            group.addTask {
                do {
                    let model = try await SCXLanguageModel.load(model: info.id, apiKey: apiKey)
                    let response = try await LanguageModelSession(model: model).respond {
                        "Which two colours are in this image? Answer with only the two colour names."
                        FoundationModels.Attachment(image([red, blue], width: 256, height: 256))
                    }
                    print("Vision \(info.id):", response.content)
                    #expect(response.content.localizedCaseInsensitiveContains("red"), "\(info.id) said: \(response.content)")
                    #expect(response.content.localizedCaseInsensitiveContains("blue"), "\(info.id) said: \(response.content)")
                } catch {
                    Issue.record("\(info.id): \(error)")
                }
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live) func loadReadsVideoSupportFromTheCatalogue() async throws {
    let apiKey = try liveKey()
    #expect(try await SCXLanguageModel.load(model: "gemma-4-31B-it", apiKey: apiKey).acceptsVideo)
    #expect(try await SCXLanguageModel.load(model: "Kimi-K3.1-Pro", apiKey: apiKey).acceptsVideo)
    #expect(try await !SCXLanguageModel.load(model: "MAGPiE", apiKey: apiKey).acceptsVideo)
}

/// The video wire format, on any iOS 27. The session path below needs iOS 27.2.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@Test(live, arguments: ["gemma-4-31B-it", "Kimi-K3.1-Pro"]) func videoReachesTheModel(_ id: String) async throws {
    let client = SCXClient(apiKey: try liveKey())
    var answer = ""
    for try await chunk in client.stream(ChatRequest(model: id, messages: [ChatMessage(role: "user", parts: [
        .text("What colour fills this video? Answer with one word."),
        .video(redClip, mediaType: "video/mp4"),
    ])])) {
        answer += chunk.choices?.first?.delta.content ?? ""
    }
    print("Video \(id):", answer)
    #expect(answer.localizedCaseInsensitiveContains("red"))
}

#if canImport(FoundationModels, _version: 2.1)
@available(iOS 27.2, macOS 27.2, visionOS 27.2, *)
@Test(live, arguments: ["gemma-4-31B-it", "Kimi-K3.1-Pro"]) func videoThroughLanguageModelSession(_ id: String) async throws {
    let model = try await SCXLanguageModel.load(model: id, apiKey: try liveKey())
    #expect(model.acceptsVideo)
    let response = try await LanguageModelSession(model: model).respond {
        "What colour fills this video? Answer with one word."
        FoundationModels.Attachment(SCXVideo(mp4: redClip))
    }
    print("Session video \(id):", response.content)
    #expect(response.content.localizedCaseInsensitiveContains("red"))
}

/// Apple's framework refuses this before the executor runs, so the fake key never reaches SCX.
@available(iOS 27.2, macOS 27.2, visionOS 27.2, *)
@Test func videoOnAModelThatDoesNotDeclareItIsRefused() async throws {
    let session = LanguageModelSession(model: SCXLanguageModel(model: "MAGPiE", apiKey: "test"))
    do {
        _ = try await session.respond { FoundationModels.Attachment(SCXVideo(mp4: redClip)) }
        Issue.record("Expected Apple's framework to refuse the video")
    } catch let error as LanguageModelError {
        print("Refused by the framework:", error)
    }
}
#endif
#endif  // canImport(FoundationModels, _version: 2)
