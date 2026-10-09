import Foundation

public enum PulseLanguage: String, CaseIterable, Codable, Sendable {
    case system, english = "en", simplifiedChinese = "zh-Hans"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
}

/// Value-based formatting: language changes never alter service data or global locale settings.
public struct PulseText: Sendable {
    public let language: PulseLanguage
    public let locale: Locale
    public init(language: PulseLanguage = .system, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = language.resolved(preferredLanguages: preferredLanguages)
        let region = Locale.current.region?.identifier ?? (self.language == .english ? "US" : "CN")
        locale = Locale(identifier: (self.language == .english ? "en_" : "zh_Hans_") + region)
    }
    public func format(_ key: String, arguments: [CVarArg] = []) -> String {
        let message = LocalizationCatalog.strings[language.rawValue]?[key]
            ?? LocalizationCatalog.strings["en"]?[key] ?? key
        guard !arguments.isEmpty else { return message }
        return String(format: message, locale: locale, arguments: arguments)
    }
    public func string(_ key: String, _ arguments: CVarArg...) -> String { format(key, arguments: arguments) }
    public func date(_ date: Date, includesDate: Bool = true) -> String {
        date.formatted(Date.FormatStyle(date: includesDate ? .abbreviated : .omitted,
                                      time: includesDate ? .shortened : .standard).locale(locale))
    }
}
