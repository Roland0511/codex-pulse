import Foundation

/// 比较已确认的额度快照，不将线程忙碌或本地计时器当作实际计费证据。
public enum ConsumptionPolicy {
    public static func detected(previous: QuotaSnapshot?, next: QuotaSnapshot) -> Bool {
        guard let previous, previous.accountKey == next.accountKey,
              next.fetchedAt > previous.fetchedAt,
              next.fetchedAt.timeIntervalSince(previous.fetchedAt) <= 180,
              next.ordinaryUsageAllowed != false, !next.hasReachedLimit else { return false }
        return next.windows.contains { window in
            guard let old = previous.windows.first(where: { $0.id == window.id }),
                  old.durationMinutes == window.durationMinutes,
                  let oldReset = old.resetsAt, let reset = window.resetsAt,
                  abs(reset.timeIntervalSince(oldReset)) <= 60,
                  reset > next.fetchedAt,
                  let used = window.usedPercent, let oldUsed = old.usedPercent else { return false }
            return used > oldUsed + 0.0001
        }
    }
}
