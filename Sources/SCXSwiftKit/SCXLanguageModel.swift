// Foundation Models gained third-party providers in the iOS 27 SDK (module version 2).
// On older toolchains this file compiles out and SCXRuntime remains usable.
#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import SCXRuntime
import UniformTypeIdentifiers

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
    /// Whether the model takes MP4 input. `load` reads this from SCX's `/v1/models`.
    public var acceptsVideo = false
    /// Largest single image the package will send, in bytes. Larger images are refused before any
    /// upload. 20 MB is SCX's limit for images.
    public var maximumImageBytes = 20_000_000
    /// Largest single video the package will send, in bytes. Larger videos are refused before any
    /// upload. 300 KB is SCX's limit for video for now. Raise it for a model that takes more.
    public var maximumVideoBytes = 300_000

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
        var loaded = SCXLanguageModel(model: model, apiKey: apiKey, baseURL: baseURL, capabilities: LanguageModelCapabilities(capabilities))
        loaded.acceptsVideo = info.inputModalities.contains("video")
        return loaded
    }

    #if canImport(FoundationModels, _version: 2.1)
    /// Apple's capability list has no video case. This is how a model declares it, and the
    /// framework checks it before a data attachment reaches the executor.
    @available(iOS 27.2, macOS 27.2, visionOS 27.2, watchOS 27.2, *)
    public nonisolated(nonsending) func supportsDataAttachmentType(_ type: UTType) async throws -> Bool {
        acceptsVideo && type.conforms(to: .mpeg4Movie)
    }
    #endif

    /// The catalogue also lists image, video, audio, embedding, moderation and System One decision
    /// models. They appear in `/v1/models` but answer `/chat/completions` with 400 "Unsupported
    /// model", so reject them here instead of at the first prompt. The test is on modalities
    /// rather than `supported_features`, so a future chat model still loads.
    static func requireTextGeneration(_ info: ModelInfo) throws {
        guard info.inputModalities.contains("text"), info.outputModalities.contains("text"),
              !info.supportedFeatures.contains("moderation"), !info.supportedFeatures.contains("systemone") else {
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
