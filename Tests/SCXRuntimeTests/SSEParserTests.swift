import Foundation
import Testing
@testable import SCXRuntime

@Test func parsesContentToolCallReasoningAndUsageLines() throws {
    let text = try SCXClient.parseSSELine(#"data: {"id":"1","choices":[{"index":0,"delta":{"content":"G'day"}}]}"#)
    #expect(text?.choices?.first?.delta.content == "G'day")

    let tool = try SCXClient.parseSSELine(
        #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"getWeather","arguments":"{\"city\":"}}]}}]}"#)
    let call = tool?.choices?.first?.delta.toolCalls?.first
    #expect(call?.id == "call_1")
    #expect(call?.function?.name == "getWeather")
    #expect(call?.function?.arguments == #"{"city":"#)

    let reasoning = try SCXClient.parseSSELine(#"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#)
    #expect(reasoning?.choices?.first?.delta.reasoningContent == "thinking")

    let filtered = try SCXClient.parseSSELine(#"data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#)
    #expect(filtered?.choices?.first?.finishReason == "content_filter")

    let usage = try SCXClient.parseSSELine(
        #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":30,"completion_tokens_details":{"reasoning_tokens":7}}}"#)
    #expect(usage?.usage?.promptTokens == 12)
    #expect(usage?.usage?.reasoningTokens == 7)

    for ignored in ["data: [DONE]", "", ": keep-alive"] {
        let chunk = try SCXClient.parseSSELine(ignored)
        #expect(chunk == nil, "\(ignored) should be ignored")
    }
}
