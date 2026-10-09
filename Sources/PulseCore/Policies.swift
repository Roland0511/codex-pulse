import Foundation

public enum DataStatus: Equatable, Sendable {
    case loading, ready, unavailable, unauthenticated, failed, stale
}

public struct QuotaState: Sendable {
    public private(set) var accountKey: String?
    public private(set) var snapshot: QuotaSnapshot?
    public private(set) var error: QuotaError?
    public init() {}
    public mutating func identify(_ key: String?) {
        if accountKey != key { snapshot = nil; error = nil; accountKey = key }
    }
    public mutating func accept(_ next: QuotaSnapshot) {
        identify(next.accountKey); snapshot = next; error = nil
    }
    public mutating func fail(_ failure: QuotaError) {
        error = failure
        if failure.clearsSnapshot { snapshot = nil; accountKey = nil }
    }
    public func status(now: Date) -> DataStatus {
        if error == .unauthenticated { return .unauthenticated }
        guard let snapshot else { return error == nil ? .loading : .unavailable }
        // 系统时钟向后跳也不能把旧快照当成新数据。
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        if age >= 180 || age < -5 { return .stale }
        if error != nil { return .failed }
        if snapshot.selectedWindow == nil { return .unavailable }
        return .ready
    }
}

public struct RefreshPolicy: Sendable {
    public private(set) var failures = 0
    public private(set) var nextAttempt: Date = .distantPast
    public init() {}
    public mutating func completed(success: Bool, now: Date, hidden: Bool) {
        failures = success ? 0 : min(failures + 1, 5)
        let interval = success ? (hidden ? 300.0 : 60.0) : min(900, 60 * pow(2, Double(failures - 1)))
        nextAttempt = now.addingTimeInterval(interval)
    }
    public mutating func resume() { nextAttempt = .distantPast }
    public mutating func visibilityChanged(hidden: Bool, lastSuccess: Date?) {
        guard failures == 0, let lastSuccess else { return }
        nextAttempt = lastSuccess.addingTimeInterval(hidden ? 300 : 60)
    }
    public func shouldRefresh(now: Date, suspended: Bool) -> Bool { !suspended && now >= nextAttempt }
}

public struct QuotaAlert: Equatable, Sendable {
    public let window: QuotaWindow
    public let threshold: Int
    public let key: String
}

public struct AlertPolicy: Codable, Sendable {
    private struct Cycle: Codable, Sendable {
        var reset: Date?
        var duration: Int?
        var used: Double
        var thresholds: Set<Int>
    }
    private var account: String?
    private var cycles: [String: Cycle] = [:]
    public init() {}

    public mutating func evaluate(_ snapshot: QuotaSnapshot) -> [QuotaAlert] {
        if account != snapshot.accountKey { cycles = [:]; account = snapshot.accountKey }
        var alerts: [QuotaAlert] = []
        let validIDs = Set(snapshot.windows.map(\.id))
        cycles = cycles.filter { validIDs.contains($0.key) }
        for window in snapshot.windows {
            guard let remaining = window.remainingPercent, let used = window.usedPercent else { continue }
            var cycle = cycles[window.id]
            if let prior = cycle, Self.isNewCycle(priorReset: prior.reset, reset: window.resetsAt,
                                                   priorUsed: prior.used, used: used, now: snapshot.fetchedAt)
                || prior.duration != window.durationMinutes {
                cycle = nil
            }
            var current = cycle ?? Cycle(reset: window.resetsAt, duration: window.durationMinutes, used: used, thresholds: [])
            let threshold: Int? = remaining <= 10 ? 10 : (remaining <= 20 ? 20 : nil)
            if let threshold, !current.thresholds.contains(threshold) {
                alerts.append(QuotaAlert(window: window, threshold: threshold,
                                         key: "\(snapshot.accountKey):\(window.id):\(current.reset?.timeIntervalSince1970 ?? 0):\(threshold)"))
                current.thresholds.insert(threshold)
                if threshold == 10 { current.thresholds.insert(20) }
            }
            current.used = used
            // 轻微服务时间修正不产生新的提醒周期。
            if current.reset == nil { current.reset = window.resetsAt }
            cycles[window.id] = current
        }
        return alerts
    }

    public static func isNewCycle(priorReset: Date?, reset: Date?, priorUsed: Double, used: Double, now: Date) -> Bool {
        guard let priorReset, let reset, reset > priorReset.addingTimeInterval(60), used < priorUsed else { return false }
        return now >= priorReset || priorUsed - used >= 20
    }
}
