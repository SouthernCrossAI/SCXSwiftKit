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

@Test func textMessageStaysAStringAndPartsBecomeAnArray() throws {
    func encoded(_ message: ChatMessage) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    }
    #expect(try encoded(ChatMessage(role: "user", content: "hi"))["content"] as? String == "hi")

    let message = try encoded(ChatMessage(role: "user", parts: [
        .text("Describe"),
        .image(Data([1, 2, 3]), mediaType: "image/png"),
        .video(Data([4, 5, 6]), mediaType: "video/mp4"),
    ]))
    let parts = try #require(message["content"] as? [[String: Any]])
    #expect(parts[0]["type"] as? String == "text")
    #expect(parts[0]["text"] as? String == "Describe")
    #expect(parts[1]["type"] as? String == "image_url")
    #expect((parts[1]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,AQID")
    #expect(parts[2]["type"] as? String == "video_url")
    #expect((parts[2]["video_url"] as? [String: String])?["url"] == "data:video/mp4;base64,BAUG")
}

@Test func attachmentByteCountAddsImagesAndVideoOnly() {
    var chat = ChatRequest(model: "m", messages: [ChatMessage(role: "user", content: "hi")])
    #expect(chat.attachmentByteCount == 0)
    chat.messages.append(ChatMessage(role: "user", parts: [
        .text("x"), .image(Data(count: 3), mediaType: "image/jpeg"), .video(Data(count: 4), mediaType: "video/mp4"),
    ]))
    #expect(chat.attachmentByteCount == 7)
}
