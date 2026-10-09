import CoreFoundation
import Foundation

public struct HookTrustSummary: Equatable, Sendable {
    public let found: Int
    public let trusted: Int
    public let enabled: Int
    public var fullyTrusted: Bool { found == ActivityEvent.allCases.count && trusted == found && enabled == found }
    public static func parse(_ data: Data, commands: Set<String>) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { throw QuotaError.invalidResponse }
        var found: Set<String> = [], enabled = 0, trusted = 0
        for entry in entries {
            guard let hooks = entry["hooks"] as? [[String: Any]] else { throw QuotaError.invalidResponse }
            for hook in hooks {
                guard let command = hook["command"] as? String, commands.contains(command) else { continue }
                guard found.insert(command).inserted,
                      let on = hook["enabled"] as? NSNumber, CFGetTypeID(on) == CFBooleanGetTypeID(),
                      let trust = hook["trustStatus"] as? String,
                      ["trusted", "untrusted", "modified", "managed"].contains(trust) else { throw QuotaError.invalidResponse }
                if on.boolValue { enabled += 1 }
                if trust == "trusted" || trust == "managed" { trusted += 1 }
            }
        }
        return .init(found: found.count, trusted: trusted, enabled: enabled)
    }
}
