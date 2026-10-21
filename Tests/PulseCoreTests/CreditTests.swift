import Foundation
import Testing
@testable import PulseCore

@Suite("充值余额与显示切换") struct CreditTests {
    private let now = Date(timeIntervalSince1970: 1893456000)

    private func parse(_ json: String) throws -> QuotaSnapshot {
        try QuotaSnapshot.parse(Data(json.utf8), accountKey: "synthetic", now: now)
    }

    @Test func anyExhaustedWindowUsesOnlyItsOwnBalance() throws {
        let snapshot = try parse(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":100},"secondary":{"usedPercent":20},"credits":{"balance":"60123.456","hasCredits":true,"unlimited":false}},"other":{"primary":{"usedPercent":100},"credits":{"balance":"999999","hasCredits":true,"unlimited":false}}}}"#)
        #expect(snapshot.displayMode == .credits(bucketID: "codex", balance: Decimal(string: "60123.456")!))
        #expect(snapshot.creditsByBucket?["codex"]?.fullBalance == "60123.456")
        let isolated = try parse(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":100}},"other":{"primary":{"usedPercent":20},"credits":{"balance":"60123","hasCredits":true,"unlimited":false}}}}"#)
        #expect(isolated.displayMode == .subscription)
    }

    @Test func legacyRecoveryAndZeroBalance() throws {
        for (used, balance, credits) in [(100, "125.75", true), (99, "125.75", false), (100, "0", false)] {
            let snapshot = try parse("""
            {"rateLimits":{"primary":{"usedPercent":\(used)},"credits":{"balance":"\(balance)","hasCredits":true,"unlimited":false}},"rateLimitResetCredits":{"availableCount":2}}
            """)
            #expect((snapshot.displayMode.creditBalance != nil) == credits)
            #expect(snapshot.availableResetCount == 2)
        }
        let empty = try parse(#"{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":100},"credits":{"balance":"60000","hasCredits":true}}}"#)
        #expect(empty.displayMode == .subscription)
        let unknown = try parse(#"{"rateLimits":{"primary":{},"credits":{"balance":"60000","hasCredits":true}}}"#)
        #expect(unknown.displayMode == .subscription)
    }

    @Test func malformedAndUnconfirmedBalancesStayUnknown() throws {
        for value in [nil, "", "-1", "NaN", "Infinity", "12xyz", "1,000", "1e6", "123456789012345678901234567890123456789"] as [String?] {
            let credits = QuotaCredits(balance: value, hasCredits: true, unlimited: false)
            #expect(credits.balance == nil)
            #expect(credits.availableBalance == nil)
        }
        #expect(QuotaCredits(balance: "60000", hasCredits: nil, unlimited: false).availableBalance == nil)
        #expect(QuotaCredits(balance: "60000", hasCredits: false, unlimited: false).availableBalance == nil)
        #expect(QuotaCredits(balance: nil, hasCredits: true, unlimited: true).availableBalance == nil)
        let numeric = try parse(#"{"rateLimits":{"primary":{"usedPercent":100},"credits":{"balance":60000,"hasCredits":true}}}"#)
        #expect(numeric.displayMode == .subscription)
        let numericFlag = try parse(#"{"rateLimits":{"primary":{"usedPercent":100},"credits":{"balance":"60000","hasCredits":1}}}"#)
        #expect(numericFlag.displayMode == .subscription)
    }

    @Test func decimalFormattingNeverRoundsUp() {
        for (raw, expected) in [("999.999", "999.9"), ("1000", "1.0k"), ("60000", "60.0k"),
                                ("60123", "60.1k"), ("999999", "999.9k"), ("1250000", "1.2M"),
                                ("1000000000", "1.0B"), ("125.750", "125.7"), ("0.005", "<0.1"),
                                ("0.019", "<0.1")] {
            #expect(CreditText.compact(Decimal(string: raw)!) == expected)
        }
        let huge = Decimal(string: "1" + String(repeating: "0", count: 100))!
        #expect(CreditText.compact(huge) == "1e100")
    }

    @Test func configurablePrecisionPreservesZerosAndPositiveRemainders() {
        let value = Decimal(string: "60123.4567")!
        #expect(CreditText.compact(value, decimalPlaces: 0) == "60k")
        #expect(CreditText.compact(value, decimalPlaces: 2) == "60.12k")
        #expect(CreditText.compact(value, decimalPlaces: 3) == "60.123k")
        #expect(CreditText.expanded(value) == "60,123.45")
        #expect(CreditText.expanded(value, decimalPlaces: 0) == "60,123")
        #expect(CreditText.expanded(value, decimalPlaces: 3) == "60,123.456")
        #expect(CreditText.expanded(60000) == "60,000.00")
        #expect(CreditText.expanded(0) == "0.00")
        for places in CreditText.decimalPlacesRange {
            let tiny = Decimal(string: "0.0007")!
            let expected = places == 0 ? "<1" : "<0." + String(repeating: "0", count: places - 1) + "1"
            #expect(CreditText.compact(tiny, decimalPlaces: places) == expected)
            #expect(CreditText.expanded(tiny, decimalPlaces: places) == expected)
        }
        #expect(CreditText.expanded(Decimal(string: "12345678901234567890.1299")!) == "12,345,678,901,234,567,890.12")
        #expect(CreditText.expanded(.nan) == "—")
        #expect(CreditText.compact(-1) == "—")
    }

    @Test func staleFailureAndAccountChangesPreserveBoundaries() throws {
        let snapshot = try parse(#"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":100},"spendControlReached":true,"credits":{"balance":"60000","hasCredits":true,"unlimited":false}}}"#)
        var state = QuotaState(); state.accept(snapshot)
        #expect(state.status(now: now) == .ready)
        #expect(state.snapshot?.hasReachedLimit == true)
        #expect(state.snapshot?.ordinaryUsageAllowed == false)
        state.fail(.disconnected)
        #expect(state.status(now: now) == .failed)
        #expect(state.snapshot?.displayMode.creditBalance == 60000)
        #expect(state.status(now: now.addingTimeInterval(181)) == .stale)
        state.identify("different-synthetic-account")
        #expect(state.snapshot == nil)
    }

    @Test func snapshotCodableRemainsBackwardCompatible() throws {
        let snapshot = try parse(#"{"rateLimits":{"primary":{"usedPercent":100},"credits":{"balance":"60000","hasCredits":true,"unlimited":false}}}"#)
        #expect(try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "creditsByBucket")
        let old = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.displayMode == .subscription)
    }
}
