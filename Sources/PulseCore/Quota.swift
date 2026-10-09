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
    public var name: String { localizedName(using: PulseText()) }
    public func localizedName(using text: PulseText) -> String {
        let period: String
        if let minutes = durationMinutes {
            if minutes % 1440 == 0 { period = text.string("period.days", minutes / 1440) }
            else if minutes % 60 == 0 { period = text.string("period.hours", minutes / 60) }
            else { period = text.string("period.minutes", minutes) }
        } else { period = text.string("quota.periodUnknown") }
        let bucket = bucketID == "demo" ? text.string("demo.bucket") : bucketName ?? bucketID
        return "\(bucket) · \(period)"
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
    public var message: String { message(using: PulseText()) }
    public func message(using text: PulseText) -> String { text.string(messageKey) }
    private var messageKey: String {
        switch self {
        case .executableMissing: "error.executableMissing"
        case .unauthenticated: "error.unauthenticated"
        case .unsupportedAccount: "error.unsupportedAccount"
        case .identityUnavailable: "error.identityUnavailable"
        case .accountChanged: "error.accountChanged"
        case .invalidResponse: "error.invalidResponse"
        case .disconnected: "error.disconnected"
        case .timedOut: "error.timedOut"
        case .permissionDenied: "error.permissionDenied"
        case .serviceUnavailable: "error.serviceUnavailable"
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
    public static func duration(_ minutes: Int, using text: PulseText = PulseText()) -> String {
        let unit = minutes % 1440 == 0 ? "days" : minutes % 60 == 0 ? "hours" : "minutes"
        let count = unit == "days" ? minutes / 1440 : unit == "hours" ? minutes / 60 : minutes
        return text.string("duration.\(unit).\(count == 1 ? "one" : "other")", count)
    }
    public static func countdown(_ reset: Date?, now: Date, using text: PulseText = PulseText(), compact: Bool = false) -> String {
        guard let reset else { return text.string("quota.resetUnknown") }
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return text.string("quota.resetDue") }
        let unit = seconds >= 86400 ? "days" : seconds >= 3600 ? "hours" : "minutes"
        let divisor = unit == "days" ? 86400.0 : unit == "hours" ? 3600.0 : 60.0
        let count = max(1, Int(ceil(seconds / divisor)))
        if compact { return text.string("countdown.\(unit)", count) }
        return text.string("countdown.full", text.string("duration.\(unit).\(count == 1 ? "one" : "other")", count))
    }
    public static func percentage(_ remaining: Double?, using text: PulseText = PulseText()) -> String {
        guard let remaining else { return text.string("quota.unknown") }
        if remaining > 0 && remaining < 1 { return "<1%" }
        return "\(Int(remaining.rounded(.down)))%"
    }
}
