import Foundation

/// Entry from `GET /v1/models`. SCX exposes per-model features here, so capabilities can be resolved at runtime.
public struct ModelInfo: Decodable, Sendable {
    public var id: String
    public var contextLength: Int?
    public var maxOutputLength: Int?
    public var supportedFeatures: [String]
    public var inputModalities: [String]
    public var outputModalities: [String]
    /// ISO country codes of the datacenters that serve the model, e.g. `["AU"]`.
    public var regions: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case contextLength = "context_length"
        case maxOutputLength = "max_output_length"
        case supportedFeatures = "supported_features"
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
        case datacenters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        maxOutputLength = try c.decodeIfPresent(Int.self, forKey: .maxOutputLength)
        supportedFeatures = try c.decodeIfPresent([String].self, forKey: .supportedFeatures) ?? []
        inputModalities = try c.decodeIfPresent([String].self, forKey: .inputModalities) ?? []
        outputModalities = try c.decodeIfPresent([String].self, forKey: .outputModalities) ?? []
        struct Datacenter: Decodable { var country_code: String? }
        regions = try c.decodeIfPresent([Datacenter].self, forKey: .datacenters)?.compactMap(\.country_code) ?? []
    }
}
