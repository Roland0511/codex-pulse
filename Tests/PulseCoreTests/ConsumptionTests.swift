import Foundation
import Testing
@testable import PulseCore

@Suite("已确认消耗") struct ConsumptionTests {
    private let time = Date(timeIntervalSince1970: 1894000000)
    private func snapshot(_ used: Double?, account: String = "synthetic", offset: Double = 60,
                          resetOffset: Double = 3600, duration: Int? = 120) -> QuotaSnapshot {
        QuotaSnapshot(accountKey: account, windows: [QuotaWindow(bucketID: "a", slot: "primary", usedPercent: used,
            durationMinutes: duration, resetsAt: time.addingTimeInterval(resetOffset))], fetchedAt: time.addingTimeInterval(offset))
    }
    @Test func onlyFreshSameCycleDecreaseTriggers() {
        let old = snapshot(30, offset: 0)
        #expect(ConsumptionPolicy.detected(previous: old, next: snapshot(31)))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(30)))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(29)))
        #expect(!ConsumptionPolicy.detected(previous: nil, next: snapshot(31)))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(nil)))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(31, account: "other")))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(31, offset: 181)))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(31, offset: -60)))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(31, resetOffset: 7200)))
        #expect(!ConsumptionPolicy.detected(previous: old, next: snapshot(31, duration: 240)))
        #expect(!ConsumptionPolicy.detected(previous: snapshot(30, offset: 0, resetOffset: 30),
                                           next: snapshot(31, resetOffset: 30)))
    }
}
