// Foundation Models gained third-party providers in the iOS 27 SDK (module version 2).
// On older toolchains this file compiles out and SCXRuntime remains usable.
#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import SCXRuntime

/// An SCX.ai hosted model (MAGPiE or any model id from `/v1/models`) for `LanguageModelSession`.
///
/// ```swift
/// let model = SCXLanguageModel(model: "MAGPiE", apiKey: key)
/// let session = LanguageModelSession(model: model)
/// let answer = try await session.respond(to: "G'day")
/// ```
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct SCXLanguageModel: LanguageModel {
    public typealias Executor = SCXExecutor

    public var model: String
    public var apiKey: String
    public var baseURL: URL
    public var capabilities: LanguageModelCapabilities
    /// Seconds the stream may stay silent between deltas. Deep reasoning can pause well past
    /// URLSession's 60 s default before the first token, so the default here is generous.
    public var timeout: TimeInterval

    public init(
        model: String = "MAGPiE",
        apiKey: String,
        baseURL: URL = SCXClient.defaultBaseURL,
        capabilities: LanguageModelCapabilities = LanguageModelCapabilities([.toolCalling, .guidedGeneration, .reasoning]),
        timeout: TimeInterval = 300
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.capabilities = capabilities
        self.timeout = timeout
    }

    /// Resolves capabilities from SCX's `/v1/models` (`supported_features`), so new SCX models need no package update.
    public static func load(model: String, apiKey: String, baseURL: URL = SCXClient.defaultBaseURL) async throws -> SCXLanguageModel {
        let infos = try await SCXClient(apiKey: apiKey, baseURL: baseURL).models()
        guard let info = infos.first(where: { $0.id == model }) else {
            throw SCXError(status: 404, type: "model_not_found", message: "Model '\(model)' is not available for this API key")
        }
        try requireTextGeneration(info)
        var capabilities: [LanguageModelCapabilities.Capability] = []
        if info.supportedFeatures.contains("tools") { capabilities.append(.toolCalling) }
        if info.supportedFeatures.contains("json_mode") { capabilities.append(.guidedGeneration) }
        if info.supportedFeatures.contains("reasoning") { capabilities.append(.reasoning) }
        if info.inputModalities.contains("image") { capabilities.append(.vision) }
        return SCXLanguageModel(model: model, apiKey: apiKey, baseURL: baseURL, capabilities: LanguageModelCapabilities(capabilities))
    }

    /// The catalogue also lists image, video, audio, embedding and moderation models. They appear
    /// in `/v1/models` but answer `/chat/completions` with 400 "Unsupported model", so reject them
    /// here instead of at the first prompt. The test is on modalities rather than
    /// `supported_features`, so a future chat model still loads.
    static func requireTextGeneration(_ info: ModelInfo) throws {
        guard info.inputModalities.contains("text"), info.outputModalities.contains("text"),
              !info.supportedFeatures.contains("moderation") else {
            let features = info.supportedFeatures.isEmpty ? "none" : info.supportedFeatures.joined(separator: ", ")
            throw SCXError(
                status: 400, type: "invalid_request_error",
                message: "Model '\(info.id)' does not generate text (SCX lists features: \(features))",
                param: "model")
        }
    }

    public var executorConfiguration: SCXExecutor.Configuration {
        SCXExecutor.Configuration(baseURL: baseURL, apiKey: apiKey, model: model, timeout: timeout)
    }
}
#endif  // canImport(FoundationModels, _version: 2)
