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
    /// 从首选格式到最紧凑格式，由原生排版层按实际宽度选择；所有截取均向下。
    public static func candidates(_ balance: Decimal) -> [String] {
        guard !balance.isNaN, balance > 0 else { return ["0"] }
        if balance < Decimal(string: "0.01")! { return ["<0.01"] }
        let suffixes = ["", "k", "M", "B", "T", "P", "E"]
        let step = Decimal(1000)
        var scaled = balance, unit = 0
        while scaled >= step, unit < suffixes.count - 1 { scaled /= step; unit += 1 }
        var result: [String] = []
        if scaled < step {
            for places in stride(from: unit == 0 ? 2 : 1, through: 0, by: -1) {
                let value = truncated(scaled, places: places) + suffixes[unit]
                if !result.contains(value) { result.append(value) }
            }
        }
        var significand = balance, exponent = 0
        while significand >= 10 { significand /= 10; exponent += 1 }
        if exponent > 0 { result.append(truncated(significand, places: 0) + "e\(exponent)") }
        return result
    }

    public static func compact(_ balance: Decimal) -> String { candidates(balance)[0] }

    private static func truncated(_ value: Decimal, places: Int) -> String {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, places, .down)
        return NSDecimalNumber(decimal: output).stringValue
    }
}
