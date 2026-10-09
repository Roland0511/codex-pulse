import Foundation

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let bucketID: String
    public let bucketName: String?
    public let slot: String
    public let usedPercent: Double?
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public var id: String { "\(bucketID):\(slot)" }
    public var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
    public var name: String {
        let period = durationMinutes.map { "\(QuotaText.duration($0))额度" } ?? "周期未知"
        return "\(bucketName ?? bucketID) · \(period)"
    }

    public init(bucketID: String, bucketName: String? = nil, slot: String,
                usedPercent: Double?, durationMinutes: Int?, resetsAt: Date?) {
        self.bucketID = bucketID; self.bucketName = bucketName; self.slot = slot
        self.usedPercent = usedPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        self.durationMinutes = durationMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.resetsAt = resetsAt
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let accountKey: String
    public let windows: [QuotaWindow]
    public let availableResetCount: Int?
    public let fetchedAt: Date
    public let ordinaryUsageAllowed: Bool?
    public let hasReachedLimit: Bool

    public init(accountKey: String, windows: [QuotaWindow], availableResetCount: Int? = nil,
                fetchedAt: Date, ordinaryUsageAllowed: Bool? = nil, hasReachedLimit: Bool = false) {
        self.accountKey = accountKey; self.windows = windows
        self.availableResetCount = availableResetCount.flatMap { $0 >= 0 ? $0 : nil }
        self.fetchedAt = fetchedAt; self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.hasReachedLimit = hasReachedLimit
    }

    public var selectedWindow: QuotaWindow? {
        windows.filter { $0.remainingPercent != nil }.sorted {
            if $0.remainingPercent != $1.remainingPercent { return $0.remainingPercent! < $1.remainingPercent! }
            if $0.resetsAt != $1.resetsAt { return ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
            return $0.id < $1.id
        }.first
    }

    public static func parse(_ data: Data, accountKey: String, now: Date) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.invalidResponse
        }
        let buckets: [String: Any]
        if let multiple = root["rateLimitsByLimitId"] as? [String: Any] {
            buckets = multiple // 空多桶响应具有权威性，不能用旧快照补全。
        } else if let legacy = root["rateLimits"] as? [String: Any] {
            buckets = [legacy["limitId"] as? String ?? "codex": legacy]
        } else { throw QuotaError.invalidResponse }
        var windows: [QuotaWindow] = []
        var reached = false
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] as? [String: Any] else { continue }
            reached = reached || bucket["rateLimitReachedType"] is String || (bucket["spendControlReached"] as? Bool == true)
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any] else { continue }
                let used = number(window["usedPercent"])
                let minutes = number(window["windowDurationMins"]).flatMap { value -> Int? in
                    guard value > 0, value < Double(Int.max), value.rounded() == value else { return nil }
                    return Int(value)
                }
                let reset = number(window["resetsAt"]).flatMap { $0 > 0 && $0 < 253402300800 ? Date(timeIntervalSince1970: $0) : nil }
                windows.append(QuotaWindow(bucketID: key, bucketName: bucket["limitName"] as? String,
                                           slot: slot, usedPercent: used, durationMinutes: minutes, resetsAt: reset))
            }
        }
        let credits = root["rateLimitResetCredits"] as? [String: Any]
        let count = number(credits?["availableCount"]).flatMap { value -> Int? in
            guard value >= 0, value < Double(Int.max), value.rounded() == value else { return nil }
            return Int(value)
        }
        return Self(accountKey: accountKey, windows: windows, availableResetCount: count,
                    fetchedAt: now, ordinaryUsageAllowed: root["ordinaryUsageAllowed"] as? Bool,
                    hasReachedLimit: reached)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

import CoreFoundation

public enum QuotaError: Error, Equatable, Sendable {
    case executableMissing, unauthenticated, unsupportedAccount, identityUnavailable
    case accountChanged, invalidResponse, disconnected, timedOut, permissionDenied, serviceUnavailable
    public var message: String {
        switch self {
        case .executableMissing: "找不到 Codex；请在设置中选择可执行文件"
        case .unauthenticated: "未登录；请打开 Codex 恢复登录"
        case .unsupportedAccount: "当前登录方式不提供套餐额度"
        case .identityUnavailable: "无法确认当前账户；请打开 Codex 检查登录"
        case .accountChanged: "账户已变化，正在重新读取"
        case .invalidResponse: "额度响应不完整；请稍后刷新"
        case .disconnected: "与 Codex 的连接已中断"
        case .timedOut: "读取超时；请稍后刷新"
        case .permissionDenied: "无权读取额度；请打开 Codex 检查登录"
        case .serviceUnavailable: "额度服务暂不可用"
        }
    }
    public var clearsSnapshot: Bool {
        switch self {
        case .unauthenticated, .unsupportedAccount, .identityUnavailable, .accountChanged, .permissionDenied: true
        default: false
        }
    }
}

public enum QuotaText {
    public static func duration(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
    public static func countdown(_ reset: Date?, now: Date) -> String {
        guard let reset else { return "重置时间未知" }
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "重置时间已到" }
        if seconds >= 86400 { return "\(Int(ceil(seconds / 86400))) 天后重置" }
        if seconds >= 3600 { return "\(Int(ceil(seconds / 3600))) 小时后重置" }
        return "\(max(1, Int(ceil(seconds / 60)))) 分钟后重置"
    }
    public static func percentage(_ remaining: Double?) -> String {
        guard let remaining else { return "未知" }
        if remaining > 0 && remaining < 1 { return "<1%" }
        return "\(Int(remaining.rounded(.down)))%"
    }
}
