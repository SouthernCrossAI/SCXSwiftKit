import Foundation

// MARK: - Client

public struct SCXClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.scx.ai/v1")!

    public var baseURL: URL
    public var apiKey: String
    public var session: URLSession

    public init(apiKey: String, baseURL: URL = SCXClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// `SCX_API_KEY`, falling back to `~/.config/scx/api_key` (the Mac user's home, also from the simulator).
    public static func apiKeyFromEnvironment() -> String? {
        if let key = ProcessInfo.processInfo.environment["SCX_API_KEY"], !key.isEmpty { return key }
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["SIMULATOR_HOST_HOME"] ?? environment["HOME"] else { return nil }
        let file = URL(filePath: home).appending(path: ".config/scx/api_key")
        let key = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    public func models() async throws -> [ModelInfo] {
        let (data, response) = try await session.data(for: request(path: "models", body: nil))
        try Self.checkStatus(response, data: data)
        struct List: Decodable { var data: [ModelInfo] }
        return try JSONDecoder().decode(List.self, from: data).data
    }

    /// Streams `POST /chat/completions` as SSE chunks. Finishes after `data: [DONE]`.
    public func stream(_ chat: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var chat = chat
                    chat.stream = true
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .withoutEscapingSlashes // base64 is full of slashes
                    let body = try encoder.encode(chat)
                    let (bytes, response) = try await session.bytes(for: request(path: "chat/completions", body: body))
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        try Self.checkStatus(response, data: data)
                    }
                    for try await line in bytes.lines {
                        if line == "data: [DONE]" { break }
                        if let chunk = try Self.parseSSELine(line) { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One SSE line to a chunk. Blank lines, comments and `[DONE]` give nil.
    public static func parseSSELine(_ line: String) throws -> ChatChunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        return try JSONDecoder().decode(ChatChunk.self, from: Data(payload.utf8))
    }

    private func request(path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        struct Envelope: Decodable {
            struct Body: Decodable { var message: String?; var type: String?; var param: String?; var code: String? }
            var error: Body?
        }
        let error = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        throw SCXError(
            status: http.statusCode,
            type: error?.type,
            message: error?.message ?? String(decoding: data, as: UTF8.self),
            param: error?.param,
            code: error?.code,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init),
            requestID: http.value(forHTTPHeaderField: "X-Request-Id"))
    }
}
