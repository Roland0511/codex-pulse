import Foundation
import Testing
@testable import PulseApp

@Suite("宿主拖动事件跟随") struct HostDragPredictionTests {
    let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
    @Test func contentDragDoesNotPredictWithoutMatchingHostMovement() {
        let host = CodexWindow(id: 42, frame: frame, isOnScreen: true)
        var prediction = HostDragPrediction(window: host, point: CGPoint(x: 120, y: 780), time: 1)
        prediction.record(CGPoint(x: 200, y: 810), at: 1.01)
        #expect(prediction.reconcile(host, at: 1.02) == nil)
        #expect(prediction.predictedFrame == nil)
    }
    @Test func confirmedDragUsesLatestPointerInsteadOfDelayedGeometry() {
        let host = CodexWindow(id: 42, frame: frame, isOnScreen: true)
        var prediction = HostDragPrediction(window: host, point: CGPoint(x: 120, y: 780), time: 1)
        prediction.record(CGPoint(x: 140, y: 790), at: 1.01)
        prediction.record(CGPoint(x: 170, y: 805), at: 1.02)
        let lagged = CodexWindow(id: 42, frame: frame.offsetBy(dx: 20, dy: 10), isOnScreen: true)
        #expect(prediction.reconcile(lagged, at: 1.025) == frame.offsetBy(dx: 50, dy: 25))
        prediction.record(CGPoint(x: 190, y: 815), at: 1.03)
        #expect(prediction.predictedFrame == frame.offsetBy(dx: 70, dy: 35))
        let resized = CodexWindow(id: 42, frame: CGRect(x: 120, y: 210, width: 900, height: 600), isOnScreen: true)
        #expect(prediction.reconcile(resized, at: 1.04) == nil)
        #expect(prediction.predictedFrame == nil)
    }
    @Test func staleOrUnrelatedWindowNeverPredicts() {
        let host = CodexWindow(id: 42, frame: frame, isOnScreen: true)
        var prediction = HostDragPrediction(window: host, point: CGPoint(x: 120, y: 780), time: 1)
        prediction.record(CGPoint(x: 140, y: 790), at: 1.01)
        #expect(prediction.reconcile(CodexWindow(id: 43, frame: frame.offsetBy(dx: 20, dy: 10), isOnScreen: true), at: 1.02) == nil)
        #expect(prediction.reconcile(CodexWindow(id: 42, frame: frame.offsetBy(dx: 20, dy: 10), isOnScreen: true), at: 1.3) == nil)
    }
}
