// Foundation Models gained third-party providers in the iOS 27 SDK (module version 2).
// On older toolchains this file compiles out and SCXRuntime remains usable.
#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import SCXRuntime

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
        let chat = try Self.chatRequest(from: request, model: configuration.model)
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
        } catch let error as SCXError where error.status == 429 || error.status == 529 {
            // 429 rate_limit_error / quota_exceeded and 529 overloaded_error are documented as
            // transient; both surface as Apple's rateLimited so apps back off and retry.
            throw LanguageModelError.rateLimited(.init(
                resetDate: error.retryAfter.map { Date(timeIntervalSinceNow: $0) },
                debugDescription: error.message))
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

    static func chatRequest(from request: LanguageModelExecutorGenerationRequest, model: String) throws -> ChatRequest {
        var chat = ChatRequest(model: model, messages: messages(from: request.transcript))
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

    static func messages(from transcript: Transcript) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                messages.append(ChatMessage(role: "system", content: text(instructions.segments)))
            case .prompt(let prompt):
                messages.append(ChatMessage(role: "user", content: text(prompt.segments)))
            case .response(let response):
                messages.append(ChatMessage(role: "assistant", content: text(response.segments)))
            case .toolCalls(let calls):
                messages.append(ChatMessage(role: "assistant", toolCalls: calls.map { call in
                    ToolCall(id: call.id, function: .init(name: call.toolName, arguments: call.arguments.jsonString))
                }))
            case .toolOutput(let output):
                messages.append(ChatMessage(role: "tool", content: text(output.segments), toolCallID: output.id))
            case .reasoning:
                break // Prior reasoning is not replayed; the answer carries forward.
            @unknown default:
                break
            }
        }
        return messages
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            default: return nil // Attachments (vision) are not supported yet.
            }
        }.joined(separator: "\n")
    }
}
#endif  // canImport(FoundationModels, _version: 2)
