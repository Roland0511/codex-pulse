import Foundation

/// Selected service tier, not measured throughput or billing telemetry.
public enum SpeedTier: String, Codable, Sendable, CaseIterable {
    case unknown, standard, fast, ultrafast

    public static func parse(_ value: String?) -> Self {
        switch value {
        case "default", "standard": .standard
        case "fast", "priority": .fast
        case "ultrafast": .ultrafast
        default: .unknown
        }
    }

    public var rank: Int {
        switch self { case .unknown: -1; case .standard: 0; case .fast: 1; case .ultrafast: 2 }
    }
}

/// Projects only the default tier and active profile from Codex's TOML.
/// Unsupported/ambiguous syntax stays unknown; no credentials or model catalog are consulted.
public struct CodexSpeedConfiguration: Equatable, Sendable {
    public let tier: SpeedTier
    public let profile: String?

    public static func parse(_ text: String) -> Self {
        var section: [String] = [], fields: [[String]: String] = [:]
        var invalid: Set<[String]> = [], multiline: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let delimiter = multiline {
                if line.contains(delimiter) { multiline = nil }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard !line.hasPrefix("[["), let end = line.lastIndex(of: "]"),
                      let path = keyPath(String(line.dropFirst().prefix(upTo: end))) else {
                    section = ["unsupported"]; continue
                }
                let suffix = line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)
                section = suffix.isEmpty || suffix.hasPrefix("#") ? path : ["unsupported"]
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let delimiter = ["\"\"\"", "'''"].first(where: { value.hasPrefix($0) }) {
                if let key = keyPath(String(line[..<equals])) {
                    let path = section + key
                    if path == ["service_tier"] || path == ["profile"] ||
                        (path.count == 3 && path[0] == "profiles" && path[2] == "service_tier") {
                        fields.removeValue(forKey: path); invalid.insert(path)
                    }
                }
                if !value.dropFirst(3).contains(delimiter) { multiline = delimiter }
                continue
            }
            guard let key = keyPath(String(line[..<equals])) else { continue }
            let path = section + key
            guard path == ["service_tier"] || path == ["profile"] ||
                    (path.count == 3 && path[0] == "profiles" && path[2] == "service_tier") else { continue }
            guard fields[path] == nil, !invalid.contains(path), let parsed = string(value) else {
                fields.removeValue(forKey: path); invalid.insert(path); continue
            }
            fields[path] = parsed
        }
        let profile = fields[["profile"]]
        if invalid.contains(["profile"]) { return Self(tier: .unknown, profile: nil) }
        let profileKey = profile.map { ["profiles", $0, "service_tier"] }
        if let profileKey, invalid.contains(profileKey) { return Self(tier: .unknown, profile: profile) }
        if let profileKey, let value = fields[profileKey] { return Self(tier: .parse(value), profile: profile) }
        return Self(tier: invalid.contains(["service_tier"]) ? .unknown : .parse(fields[["service_tier"]]), profile: profile)
    }

    private static func string(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var escaped = false
        for index in text.indices.dropFirst() {
            let character = text[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            guard character == quote else { continue }
            let suffix = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
            guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }
            if quote == "'" { return String(text[text.index(after: text.startIndex)..<index]) }
            return try? JSONDecoder().decode(String.self, from: Data(text[...index].utf8))
        }
        return nil
    }

    private static func keyPath(_ text: String) -> [String]? {
        var result: [String] = [], segment = "", quote: Character?, escaped = false
        for character in text.trimmingCharacters(in: .whitespaces) {
            if let delimiter = quote {
                segment.append(character)
                if escaped { escaped = false }
                else if delimiter == "\"", character == "\\" { escaped = true }
                else if character == delimiter { quote = nil }
            } else if character == "\"" || character == "'" { quote = character; segment.append(character) }
            else if character == "." { result.append(segment); segment = "" }
            else { segment.append(character) }
        }
        guard quote == nil else { return nil }
        result.append(segment)
        return result.reduce(into: Optional<[String]>([])) { values, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let value = trimmed.first == "\"" || trimmed.first == "'" ? string(trimmed) :
                (!trimmed.isEmpty && trimmed.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } ? trimmed : nil)
            if let value, values != nil { values?.append(value) } else { values = nil }
        }
    }
}
