import Foundation

// MARK: - Chat Completions types (OpenAI wire format)

public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    public init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct ToolCall: Codable, Sendable {
    public var id: String
    public var type: String
    public var function: Function

    public struct Function: Codable, Sendable {
        public var name: String
        public var arguments: String
        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public init(id: String, function: Function) {
        self.id = id
        self.type = "function"
        self.function = function
    }
}

public struct ChatRequest: Encodable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var stream = true
    public var streamOptions = ["include_usage": true]
    public var temperature: Double?
    public var maxTokens: Int?
    public var topK: Int?
    public var topP: Double?
    public var seed: Int?
    public var tools: [JSONValue]?
    public var toolChoice: JSONValue?
    public var responseFormat: JSONValue?
    public var reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools, seed
        case streamOptions = "stream_options"
        case maxTokens = "max_tokens"
        case topK = "top_k"
        case topP = "top_p"
        case toolChoice = "tool_choice"
        case responseFormat = "response_format"
        case reasoningEffort = "reasoning_effort"
    }

    public init(model: String, messages: [ChatMessage]) {
        self.model = model
        self.messages = messages
    }
}

/// One streamed chunk (`data:` line) of a chat completion.
public struct ChatChunk: Decodable, Sendable {
    public var id: String?
    public var model: String?
    public var choices: [Choice]?
    public var usage: Usage?

    public struct Choice: Decodable, Sendable {
        public var index: Int?
        public var delta: Delta
        public var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    public struct Delta: Decodable, Sendable {
        public var content: String?
        /// Reasoning text. Providers use `reasoning_content` (vLLM, DeepSeek) or `reasoning`.
        public var reasoningContent: String?
        public var toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content, reasoning
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            content = try c.decodeIfPresent(String.self, forKey: .content)
            reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
                ?? c.decodeIfPresent(String.self, forKey: .reasoning)
            toolCalls = try c.decodeIfPresent([ToolCallDelta].self, forKey: .toolCalls)
        }
    }

    public struct ToolCallDelta: Decodable, Sendable {
        public var index: Int?
        public var id: String?
        public var function: Function?

        public struct Function: Decodable, Sendable {
            public var name: String?
            public var arguments: String?
        }
    }

    public struct Usage: Decodable, Sendable {
        public var promptTokens = 0
        public var completionTokens = 0
        public var cachedTokens = 0
        public var reasoningTokens = 0

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case completionTokensDetails = "completion_tokens_details"
        }

        private struct Details: Decodable {
            var cached_tokens: Int?
            var reasoning_tokens: Int?
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
            completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
            cachedTokens = try c.decodeIfPresent(Details.self, forKey: .promptTokensDetails)?.cached_tokens ?? 0
            reasoningTokens = try c.decodeIfPresent(Details.self, forKey: .completionTokensDetails)?.reasoning_tokens ?? 0
        }
    }
}
