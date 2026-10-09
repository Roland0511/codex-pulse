import Foundation

public struct ChromeColors: Equatable, Sendable {
    public let surface: UInt32
    public let ink: UInt32
    public let accent: UInt32
}

public struct CodexAppearance: Equatable, Sendable {
    public var mode: String = "system"
    public var light: ChromeColors?
    public var dark: ChromeColors?

    /// 只识别当前 Codex 写入的外观表；不解析其它配置值、身份或认证字段。
    /// 未支持的 TOML 写法保持未知，不猜测配色。
    public static func parse(_ text: String) -> Self? {
        var section = "", multiline: String?
        var fields: [String: [String: String]] = [:]
        let sections = ["desktop", "desktop.appearanceLightChromeTheme", "desktop.appearanceDarkChromeTheme"]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let delimiter = multiline {
                if line.contains(delimiter) { multiline = nil }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let equals = line.firstIndex(of: "=") {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
                    if !value.dropFirst(3).contains(delimiter) { multiline = delimiter }
                }
                if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") { continue }
            }
            if line.hasPrefix("[") {
                guard !line.hasPrefix("[["), let end = line.firstIndex(of: "]") else { section = ""; continue }
                section = line[line.index(after: line.startIndex)..<end].split(separator: ".").map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }.joined(separator: ".")
                continue
            }
            guard sections.contains(section), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard (section == "desktop" && key == "appearanceTheme") ||
                  (section != "desktop" && ["surface", "ink", "accent"].contains(key)) else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote) else { continue }
            let suffix = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard suffix.isEmpty || suffix.hasPrefix("#") else { continue }
            fields[section, default: [:]][key] = String(value[value.index(after: value.startIndex)..<end])
        }
        func colors(_ section: String) -> ChromeColors? {
            func hex(_ key: String) -> UInt32? {
                guard let value = fields[section]?[key], value.count == 7, value.first == "#" else { return nil }
                return UInt32(value.dropFirst(), radix: 16)
            }
            guard let surface = hex("surface"), let ink = hex("ink"), let accent = hex("accent") else { return nil }
            return ChromeColors(surface: surface, ink: ink, accent: accent)
        }
        let mode = fields["desktop"]?["appearanceTheme"] ?? "system"
        guard ["system", "light", "dark"].contains(mode) else { return nil }
        let light = colors(sections[1]), dark = colors(sections[2])
        guard light != nil || dark != nil else { return nil }
        return Self(mode: mode, light: light, dark: dark)
    }
}
