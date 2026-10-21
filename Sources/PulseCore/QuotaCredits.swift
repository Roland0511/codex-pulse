import Foundation

public struct QuotaCredits: Codable, Equatable, Sendable {
    public let balance: Decimal?
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let fullBalance: String?

    public init(balance raw: String?, hasCredits: Bool?, unlimited: Bool?) {
        self.hasCredits = hasCredits; self.unlimited = unlimited
        // 协议是十进制字符串。拒绝部分解析、负数和非有限值，避免假余额。
        if let raw, raw.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
           raw.filter({ $0 != "." }).drop(while: { $0 == "0" }).reversed().drop(while: { $0 == "0" }).count <= 38,
           let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN,
           value > 0 || !raw.contains(where: { $0 >= "1" && $0 <= "9" }) {
            balance = value; fullBalance = raw
        } else { balance = nil; fullBalance = nil }
    }

    public var availableBalance: Decimal? {
        guard hasCredits == true, let balance, balance > 0 else { return nil }
        return balance
    }
}

public enum QuotaDisplayMode: Equatable, Sendable {
    case subscription
    case credits(bucketID: String, balance: Decimal)

    public var creditBalance: Decimal? {
        if case let .credits(_, balance) = self { return balance }
        return nil
    }
}

public enum CreditText {
    public static let decimalPlacesRange = 0...3

    /// 从首选格式到最紧凑格式，由原生排版层按实际宽度选择；所有截取均向下。
    public static func candidates(_ balance: Decimal, decimalPlaces: Int = 1) -> [String] {
        let places = normalizedPlaces(decimalPlaces)
        guard !balance.isNaN, balance >= 0 else { return ["—"] }
        let suffixes = ["", "k", "M", "B", "T", "P", "E"]
        let step = Decimal(1000)
        var scaled = balance, unit = 0
        while scaled >= step, unit < suffixes.count - 1 { scaled /= step; unit += 1 }
        var result: [String] = []
        if scaled < step {
            for count in stride(from: places, through: 0, by: -1) {
                let value = fixed(scaled, places: count) + suffixes[unit]
                if !result.contains(value) { result.append(value) }
            }
        }
        var significand = balance, exponent = 0
        while significand >= 10 { significand /= 10; exponent += 1 }
        if exponent > 0 { result.append(fixed(significand, places: 0) + "e\(exponent)") }
        return result
    }

    public static func compact(_ balance: Decimal, decimalPlaces: Int = 1) -> String {
        candidates(balance, decimalPlaces: decimalPlaces)[0]
    }

    /// 详情用原值截取并分组，不能先经紧凑缩写或 Double 转换损失精度。
    public static func expanded(_ balance: Decimal, decimalPlaces: Int = 2) -> String {
        guard !balance.isNaN, balance >= 0 else { return "—" }
        let value = fixed(balance, places: normalizedPlaces(decimalPlaces))
        guard !value.hasPrefix("<") else { return value }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let digits = Array(parts[0])
        let integer = digits.enumerated().map { index, digit in
            (index > 0 && (digits.count - index) % 3 == 0 ? "," : "") + String(digit)
        }.joined()
        return integer + (parts.count == 2 ? "." + parts[1] : "")
    }

    private static func normalizedPlaces(_ places: Int) -> Int {
        min(decimalPlacesRange.upperBound, max(decimalPlacesRange.lowerBound, places))
    }

    private static func fixed(_ value: Decimal, places: Int) -> String {
        let minimum = Decimal(sign: .plus, exponent: -places, significand: 1)
        if value > 0, value < minimum { return "<" + fixed(minimum, places: places) }
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, places, .down)
        let raw = NSDecimalNumber(decimal: output).stringValue
        guard places > 0 else { return raw }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        return String(parts[0]) + "." + fraction + String(repeating: "0", count: max(0, places - fraction.count))
    }
}
