import Foundation

// MARK: - Errors

public struct SCXError: Error, Sendable, CustomStringConvertible {
    public var status: Int
    public var type: String?
    public var message: String
    /// Offending field, e.g. "messages" for a too-long prompt, "temperature" for a bad value.
    public var param: String?
    public var code: String?
    public var retryAfter: TimeInterval?
    public var requestID: String?

    public init(status: Int, type: String? = nil, message: String, param: String? = nil, code: String? = nil,
                retryAfter: TimeInterval? = nil, requestID: String? = nil) {
        self.status = status
        self.type = type
        self.message = message
        self.param = param
        self.code = code
        self.retryAfter = retryAfter
        self.requestID = requestID
    }

    public var description: String {
        "SCX API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
    }
}
