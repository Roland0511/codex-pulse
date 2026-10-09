import CoreGraphics
import Foundation
import Testing
@testable import PulseCore

private let sampleTime = Date(timeIntervalSince1970: 1893456000)

private func fixture(_ name: String) throws -> QuotaSnapshot {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try QuotaSnapshot.parse(Data(contentsOf: url), accountKey: "synthetic-account", now: sampleTime)
}
private func snapshot(_ used: Double, account: String = "a", reset: Date? = sampleTime.addingTimeInterval(300), now: Date = sampleTime) -> QuotaSnapshot {
    QuotaSnapshot(accountKey: account, windows: [QuotaWindow(bucketID: "codex", slot: "primary", usedPercent: used,
                      durationMinutes: 300, resetsAt: reset)], fetchedAt: now)
}

@Suite("额度解析与显示") struct QuotaTests {
    @Test func onlyWeeklyDoesNotBecomeFiveHours() throws {
        let q = try fixture("weekly")
        #expect(q.windows.count == 1)
        #expect(q.selectedWindow?.durationMinutes == 10080)
        #expect(q.selectedWindow?.remainingPercent == 97)
        #expect(q.availableResetCount == 0)
    }
    @Test func legacyDual() throws {
        let q = try fixture("dual")
        #expect(q.windows.count == 2)
        #expect(q.selectedWindow?.durationMinutes == 10080)
        #expect(q.availableResetCount == nil)
    }
    @Test func multipleOverridesLegacyAndKeepsUnknown() throws {
        let q = try fixture("multiple")
        #expect(q.windows.count == 3)
        #expect(q.selectedWindow?.bucketID == "extra")
        #expect(q.selectedWindow?.remainingPercent == 15)
        #expect(q.windows.first(where: { $0.slot == "secondary" })?.remainingPercent == nil)
        #expect(q.availableResetCount == 2)
    }
    @Test func emptyMultiIsAuthoritative() throws {
        let q = try fixture("empty")
        #expect(q.windows.isEmpty)
        #expect(q.selectedWindow == nil)
    }
    @Test func invalidValuesStayUnknown() throws {
        let q = try fixture("malformed-fields")
        #expect(q.windows.allSatisfy { $0.remainingPercent == nil })
        #expect(q.windows.allSatisfy { $0.durationMinutes == nil && $0.resetsAt == nil })
        #expect(q.availableResetCount == nil)
    }
    @Test func numericLimitsAndFraction() {
        #expect(snapshot(150).selectedWindow?.remainingPercent == 0)
        #expect(snapshot(-1).selectedWindow?.remainingPercent == 100)
        #expect(snapshot(.nan).selectedWindow == nil)
        #expect(QuotaText.percentage(0.4) == "<1%")
    }
    @Test func countdownNeverClaimsReset() {
        let text = PulseText(language: .simplifiedChinese)
        #expect(QuotaText.countdown(sampleTime.addingTimeInterval(-1), now: sampleTime, using: text) == "重置时间已到")
        #expect(QuotaText.countdown(nil, now: sampleTime, using: text) == "重置时间未知")
        #expect(QuotaText.countdown(sampleTime.addingTimeInterval(1), now: sampleTime, using: text) == "1 分钟后重置")
    }
    @Test func tiesUseEarlierResetThenStableID() {
        let a = QuotaWindow(bucketID: "a", slot: "primary", usedPercent: 40, durationMinutes: 30, resetsAt: sampleTime)
        let b = QuotaWindow(bucketID: "b", slot: "primary", usedPercent: 40, durationMinutes: 60, resetsAt: sampleTime.addingTimeInterval(60))
        #expect(QuotaSnapshot(accountKey: "a", windows: [b,a], fetchedAt: sampleTime).selectedWindow?.id == a.id)
    }
}

@Suite("缓存、提醒与刷新策略") struct PolicyTests {
    @Test func failedCacheStaleAndClockChange() {
        var state = QuotaState()
        #expect(state.status(now: sampleTime) == .loading)
        state.accept(snapshot(30)); state.fail(.disconnected)
        #expect(state.snapshot != nil)
        #expect(state.status(now: sampleTime) == .failed)
        #expect(state.status(now: sampleTime.addingTimeInterval(181)) == .stale)
        #expect(state.status(now: sampleTime.addingTimeInterval(-60)) == .stale)
        state.accept(snapshot(20, now: sampleTime.addingTimeInterval(200)))
        #expect(state.status(now: sampleTime.addingTimeInterval(200)) == .ready)
    }
    @Test func accountAndPermissionClearCache() {
        var state = QuotaState(); state.accept(snapshot(20))
        state.identify("other"); #expect(state.snapshot == nil)
        for error in [QuotaError.unauthenticated, .permissionDenied, .accountChanged, .identityUnavailable] {
            state.accept(snapshot(20)); state.fail(error); #expect(state.snapshot == nil)
        }
    }
    @Test func thresholdsCrossOnlyOnce() {
        var policy = AlertPolicy()
        #expect(policy.evaluate(snapshot(50)).isEmpty)
        #expect(policy.evaluate(snapshot(80)).map(\.threshold) == [20])
        #expect(policy.evaluate(snapshot(81)).isEmpty)
        #expect(policy.evaluate(snapshot(90)).map(\.threshold) == [10])
        #expect(policy.evaluate(snapshot(99)).isEmpty)
    }
    @Test func firstReadBelowTenOnlyOneAlert() {
        var policy = AlertPolicy()
        #expect(policy.evaluate(snapshot(95)).map(\.threshold) == [10])
        #expect(policy.evaluate(snapshot(83)).isEmpty)
    }
    @Test func resetJitterDoesNotRepeatAndConfirmedNewPeriodDoes() {
        var policy = AlertPolicy()
        #expect(policy.evaluate(snapshot(91)).count == 1)
        #expect(policy.evaluate(snapshot(92, reset: sampleTime.addingTimeInterval(301))).isEmpty)
        #expect(policy.evaluate(snapshot(91, reset: sampleTime.addingTimeInterval(600))).isEmpty)
        #expect(policy.evaluate(snapshot(2, reset: sampleTime.addingTimeInterval(1000), now: sampleTime.addingTimeInterval(400))).isEmpty)
        #expect(policy.evaluate(snapshot(91, reset: sampleTime.addingTimeInterval(1000), now: sampleTime.addingTimeInterval(401))).count == 1)
    }
    @Test func accountAndBucketDedupIndependent() {
        var policy = AlertPolicy()
        #expect(policy.evaluate(snapshot(95, account: "a")).count == 1)
        #expect(policy.evaluate(snapshot(95, account: "b")).count == 1)
        let base = snapshot(95, account: "b")
        let extra = QuotaWindow(bucketID: "extra", slot: "primary", usedPercent: 95, durationMinutes: 60, resetsAt: sampleTime)
        #expect(policy.evaluate(QuotaSnapshot(accountKey: "b", windows: base.windows + [extra], fetchedAt: sampleTime)).count == 1)
    }
    @Test func persistedDedupSurvivesRestart() throws {
        var policy = AlertPolicy(); _ = policy.evaluate(snapshot(95))
        var restored = try JSONDecoder().decode(AlertPolicy.self, from: JSONEncoder().encode(policy))
        #expect(restored.evaluate(snapshot(95)).isEmpty)
    }
    @Test func backoffCappedAndSuspension() {
        var policy = RefreshPolicy()
        policy.completed(success: true, now: sampleTime, hidden: false)
        #expect(policy.nextAttempt == sampleTime.addingTimeInterval(60))
        policy.completed(success: true, now: sampleTime, hidden: true)
        #expect(policy.nextAttempt == sampleTime.addingTimeInterval(300))
        for _ in 0..<10 { policy.completed(success: false, now: sampleTime, hidden: false) }
        #expect(policy.nextAttempt == sampleTime.addingTimeInterval(900))
        #expect(!policy.shouldRefresh(now: sampleTime.addingTimeInterval(1000), suspended: true))
        policy.resume(); #expect(policy.shouldRefresh(now: sampleTime, suspended: false))
    }
    @Test func showingRestoresMinutePollingWithoutResettingBackoff() {
        var policy = RefreshPolicy()
        policy.completed(success: true, now: sampleTime, hidden: true)
        policy.visibilityChanged(hidden: false, lastSuccess: sampleTime)
        #expect(policy.nextAttempt == sampleTime.addingTimeInterval(60))
        policy.completed(success: false, now: sampleTime, hidden: false)
        policy.completed(success: false, now: sampleTime, hidden: false)
        policy.visibilityChanged(hidden: false, lastSuccess: sampleTime)
        #expect(policy.nextAttempt == sampleTime.addingTimeInterval(120))
    }
}

@Suite("屏幕几何与吸附") struct GeometryTests {
    @Test func restoredPositionFitsNegativeOriginAndSmallScreen() {
        let visible = CGRect(x: -1440, y: 50, width: 1440, height: 850)
        let saved = OverlayPosition(screenID: "synthetic", x: 1, y: 1, side: .right)
        let frame = saved.frame(in: visible, size: CGSize(width: 54, height: 36))
        #expect(frame.maxX == visible.maxX && frame.maxY == visible.maxY)
        let fallback = saved.frame(in: CGRect(x: 0, y: 0, width: 30, height: 20), size: CGSize(width: 180, height: 36))
        #expect(fallback.minX == 0 && fallback.minY == 0 && fallback.width == 30)
    }
    @Test func positionRoundTrip() {
        let visible = CGRect(x: 0, y: 50, width: 1200, height: 800), frame = CGRect(x: 200, y: 300, width: 180, height: 36)
        let position = OverlayPosition.capture(frame: frame, visible: visible, screenID: "s", side: nil)
        #expect(position.frame(in: visible, size: frame.size) == frame)
    }
    @Test func symmetricAttachmentTravel() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let left = Attachment.calculate(intended: CGRect(x: 16, y: 200, width: 180, height: 36), visible: visible)
        let right = Attachment.calculate(intended: CGRect(x: 804, y: 200, width: 180, height: 36), visible: visible)
        #expect(left.side == .left && right.side == .right && left.progress == right.progress)
        #expect(left.progress == 0.5)
        #expect(Attachment.calculate(intended: CGRect(x: 33, y: 200, width: 180, height: 36), visible: visible).side == nil)
        #expect(Attachment.calculate(intended: CGRect(x: -10, y: 200, width: 180, height: 36), visible: visible).progress == 1)
    }
}
