import Foundation

public struct SpeedMetadataUpdate: Equatable, Sendable {
    public let session: String
    public let tier: SpeedTier

    /// Project only the service-tier notification. Other payloads are skipped as bytes,
    /// including messages, titles, tool arguments, and results; no JSON tree is built.
    public static func read(_ data: Data) -> Self? {
        guard let fields = try? SpeedJSONProjection.read(data), fields["id"] == nil,
              fields["method"] == "thread/settings/updated",
              let id = fields["params.threadId"], UUID(uuidString: id) != nil,
              let raw = fields["params.threadSettings.serviceTier"] else { return nil }
        let tier: SpeedTier = raw == "null" ? .standard : .parse(raw)
        guard tier != .unknown else { return nil }
        return Self(session: ActivitySignal.hash(id), tier: tier)
    }
}

public enum SpeedJSONProjection {
    public static func read(_ data: Data) throws -> [String: String] {
        try JSONMetadataProjection.read(data, paths: ["method", "id", "result", "error", "params.threadId", "params.threadSettings.serviceTier"], presencePaths: ["result", "error"])
    }
}
