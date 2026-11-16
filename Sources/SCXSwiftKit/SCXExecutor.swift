// Foundation Models gained third-party providers in the iOS 27 SDK (module version 2).
// On older toolchains this file compiles out and SCXRuntime remains usable.
#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import ImageIO
import SCXRuntime
import UniformTypeIdentifiers
#if !os(watchOS)
import CoreImage
#endif

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct SCXExecutor: LanguageModelExecutor {
    public typealias Model = SCXLanguageModel

    public struct Configuration: Hashable, Sendable {
        public var baseURL: URL
        public var apiKey: String
        public var model: String
        public var timeout: TimeInterval

        public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.timeout = timeout
        }
    }

    let configuration: Configuration
    let client: SCXClient

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        self.client = SCXClient(
            apiKey: configuration.apiKey,
            baseURL: configuration.baseURL,
            session: URLSession(configuration: sessionConfiguration))
    }

    public func prewarm(model: SCXLanguageModel, transcript: Transcript) {
        let client = client
        Task { _ = try? await client.models() } // warms DNS and TLS; the result is discarded
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: SCXLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let chat = try Self.chatRequest(from: request, model: model)
        await channel.send(.response(action: .updateMetadata([
            "modelID": configuration.model,
            "requestID": request.id.uuidString,
        ])))

        // ponytail: assumes the first delta of a tool call carries both id and name (OpenAI, vLLM do).
        var toolCalls: [Int: (id: String, name: String)] = [:]
        do {
            for try await chunk in client.stream(chat) {
                for choice in chunk.choices ?? [] {
                    if let reasoning = choice.delta.reasoningContent, !reasoning.isEmpty {
                        await channel.send(.reasoning(action: .appendText(reasoning, tokenCount: 1)))
                    }
                    if let text = choice.delta.content, !text.isEmpty {
                        await channel.send(.response(action: .appendText(text, tokenCount: 1)))
                    }
                    for call in choice.delta.toolCalls ?? [] {
                        let index = call.index ?? 0
                        if let id = call.id, let name = call.function?.name { toolCalls[index] = (id, name) }
                        guard let known = toolCalls[index] else { continue }
                        await channel.send(.toolCalls(action: .toolCall(
                            id: known.id, name: known.name,
                            action: .appendArguments(call.function?.arguments ?? "", tokenCount: 1))))
                    }
                    if choice.finishReason == "content_filter" {
                        throw LanguageModelError.guardrailViolation(.init(
                            debugDescription: "SCX guardrails filtered the content"))
                    }
                }
                if let usage = chunk.usage {
                    await channel.send(.response(action: .updateUsage(
                        input: .init(totalTokenCount: usage.promptTokens, cachedTokenCount: usage.cachedTokens),
                        output: .init(totalTokenCount: usage.completionTokens, reasoningTokenCount: usage.reasoningTokens))))
                }
            }
        // Model-level refusals are not mapped: MAGPiE refuses inline (finish_reason "stop", text
        // in `content`), indistinguishable from a normal answer, and streams through as assistant
        // text. Platform Guardrails end the stream with finish_reason "content_filter" instead,
        // mapped above per SCX engineering. See docs/PROVIDER-NOTES.md.
        } catch let error as SCXError where Self.isTemporary(error) {
            // 429 rate_limit_error / quota_exceeded, 503 when the upstream provider is down for a
            // moment and 529 overloaded_error surface as Apple's rateLimited so apps back off and retry.
            throw LanguageModelError.rateLimited(.init(
                resetDate: error.retryAfter.map { Date(timeIntervalSinceNow: $0) },
                debugDescription: error.message))
        } catch let error as SCXError where Self.isAttachmentRefusal(error, of: chat) {
            throw Self.attachmentRefused(error, chat: chat, transcript: request.transcript)
        } catch let error as SCXError where (error.status == 400 && error.param == "messages") || error.status == 413 {
            // 400/messages: currently "The request exceeds the model's context window. Reduce the
            // input or lower max_tokens." SCX rewords it, so the guard reads the status and the
            // param. 413: body over the endpoint size cap. Both are an oversized request.
            // ponytail: token counts are not in the error, 0s until SCX exposes them.
            throw LanguageModelError.contextSizeExceeded(.init(
                contextSize: 0, tokenCount: 0, debugDescription: error.message))
        // Other URLErrors (offline, connection lost, DNS) propagate: LanguageModelError has no network case.
        } catch let error as URLError where error.code == .timedOut {
            throw LanguageModelError.timeout(.init(debugDescription: error.localizedDescription))
        }
    }

    // MARK: Request mapping

    static func chatRequest(from request: LanguageModelExecutorGenerationRequest, model: SCXLanguageModel) throws -> ChatRequest {
        var chat = ChatRequest(model: model.model, messages: try messages(from: request.transcript, model: model))
        let options = request.generationOptions

        // SCX accepts temperature 0...1 (OpenAI allows 0...2).
        chat.temperature = options.temperature.map { min(max($0, 0), 1) }
        chat.maxTokens = options.maximumResponseTokens
        switch options.samplingMode?.kind {
        case .greedy?:
            chat.temperature = 0
        case .randomTopK(let k, let seed)?:
            chat.topK = k
            chat.seed = seed.map { Int(clamping: $0) }
        case .randomProbabilityThreshold(let p, let seed)?:
            chat.topP = p
            chat.seed = seed.map { Int(clamping: $0) }
        default:
            break
        }

        if !request.enabledToolDefinitions.isEmpty {
            chat.tools = try request.enabledToolDefinitions.map { tool in
                .object(["type": .string("function"), "function": .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": try JSONValue(jsonData: JSONEncoder().encode(tool.parameters)),
                ])])
            }
            switch options.toolCallingMode?.kind {
            case .required: chat.toolChoice = .string("required")
            case .disallowed: chat.toolChoice = .string("none")
            default: break
            }
        }

        if let schema = request.schema {
            chat.responseFormat = .object(["type": .string("json_schema"), "json_schema": .object([
                "name": .string("response"),
                "strict": .bool(false), // SCX: strict mode is not supported yet.
                "schema": try JSONValue(jsonData: JSONEncoder().encode(schema)),
            ])])
        }

        switch request.contextOptions.reasoningLevel {
        case .light?: chat.reasoningEffort = "low"
        case .moderate?: chat.reasoningEffort = "medium"
        case .deep?: chat.reasoningEffort = "high"
        case .custom(let value)?: chat.reasoningEffort = value
        default: break
        }
        return chat
    }

    static func messages(from transcript: Transcript, model: SCXLanguageModel) throws -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                messages.append(ChatMessage(role: "system", content: try text(instructions.segments, of: entry)))
            case .prompt(let prompt):
                messages.append(try userMessage(prompt.segments, of: entry, model: model))
            case .response(let response):
                messages.append(ChatMessage(role: "assistant", content: try text(response.segments, of: entry)))
            case .toolCalls(let calls):
                messages.append(ChatMessage(role: "assistant", toolCalls: calls.map { call in
                    ToolCall(id: call.id, function: .init(name: call.toolName, arguments: call.arguments.jsonString))
                }))
            case .toolOutput(let output):
                messages.append(ChatMessage(role: "tool", content: try text(output.segments, of: entry), toolCallID: output.id))
            case .reasoning:
                break // Prior reasoning is not replayed; the answer carries forward.
            default:
                break
            }
        }
        return messages
    }

    static func text(_ segments: [Transcript.Segment], of entry: Transcript.Entry) throws -> String {
        try segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            case .attachment: throw unsupported([entry], "SCX takes images and video in prompts only.")
            default: return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: Attachments

    /// Stays a plain string unless the prompt has an attachment, so text requests do not change.
    static func userMessage(_ segments: [Transcript.Segment], of entry: Transcript.Entry, model: SCXLanguageModel) throws -> ChatMessage {
        guard segments.contains(where: isAttachment) else {
            return ChatMessage(role: "user", content: try text(segments, of: entry))
        }
        return ChatMessage(role: "user", parts: try segments.compactMap { segment -> ContentPart? in
            if case .attachment(let attachment) = segment {
                return try part(for: attachment.content, of: entry, model: model)
            }
            let content = try text([segment], of: entry)
            return content.isEmpty ? nil : .text(content)
        })
    }

    static func part(for attachment: Transcript.Attachment, of entry: Transcript.Entry, model: SCXLanguageModel) throws -> ContentPart {
        let part: ContentPart
        let limit: Int
        switch attachment {
        case .image(let image):
            guard model.capabilities.contains(.vision) else {
                throw LanguageModelError.unsupportedCapability(.init(
                    capability: .vision,
                    debugDescription: "'\(model.model)' is not set up for images. Create it with SCXLanguageModel.load(model:apiKey:), which reads what the model accepts from /v1/models."))
            }
            guard let encoded = encodedImage(image) else {
                throw unsupported([entry], "The image could not be encoded as JPEG or PNG.")
            }
            part = encoded
            limit = model.maximumImageBytes
        #if canImport(FoundationModels, _version: 2.1)
        case .data(let data):
            part = .video(data.content, mediaType: "video/mp4") // supportsDataAttachmentType lets only MP4 through
            limit = model.maximumVideoBytes
        #endif
        default:
            throw unsupported([entry], "SCX takes JPEG or PNG images and MP4 video.")
        }
        guard part.byteCount <= limit else {
            throw unsupported([entry], "This attachment is \(size(part.byteCount)). The limit is \(size(limit)).")
        }
        return part
    }

    /// Re-encodes every image, which covers HEIC files, pixel buffers and rotated photos with one
    /// path. PNG only when the image has an alpha channel, because JPEG would lose it.
    static func encodedImage(_ image: Transcript.ImageAttachment) -> ContentPart? {
        var pixels = image.cgImage
        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(pixels.alphaInfo)
        // ponytail: watchOS has no ciImage, so rotated images go as stored there. No camera on a watch.
        #if !os(watchOS)
        if image.orientation != .up { // Turn the pixels, so no model has to read an EXIF tag.
            let upright = image.ciImage.oriented(image.orientation)
            pixels = CIContext().createCGImage(upright, from: upright.extent) ?? pixels
        }
        #endif
        let type: UTType = isOpaque ? .jpeg : .png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let mediaType = type.preferredMIMEType else { return nil }
        return .image(data as Data, mediaType: mediaType)
    }

    static func isTemporary(_ error: SCXError) -> Bool {
        [429, 503, 529].contains(error.status)
    }

    /// An oversized attachment comes back as a 400 that names no field and no size, for example
    /// "The request was rejected as invalid." (see docs/PROVIDER-NOTES.md).
    static func isAttachmentRefusal(_ error: SCXError, of chat: ChatRequest) -> Bool {
        chat.attachmentByteCount > 0 && ((error.status == 400 && error.param == nil) || error.status == 413)
    }

    static func attachmentRefused(_ error: SCXError, chat: ChatRequest, transcript: Transcript) -> LanguageModelError {
        let entries = transcript.filter { entry in
            guard case .prompt(let prompt) = entry else { return false }
            return prompt.segments.contains(where: isAttachment)
        }
        return unsupported(Array(entries), "\(chat.model) refused \(size(chat.attachmentByteCount)) of attachments. The file may be over this model's limit or of a type it does not take. SCX said: \(error.message)")
    }

    private static func isAttachment(_ segment: Transcript.Segment) -> Bool {
        if case .attachment = segment { true } else { false }
    }

    private static func size(_ bytes: Int) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private static func unsupported(_ entries: [Transcript.Entry], _ description: String) -> LanguageModelError {
        .unsupportedTranscriptContent(.init(unsupportedContent: entries, debugDescription: description))
    }
}
#endif  // canImport(FoundationModels, _version: 2)
