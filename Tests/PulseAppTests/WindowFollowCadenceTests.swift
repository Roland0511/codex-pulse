import Testing
@testable import PulseApp

@Suite("窗口位置自适应调度") struct WindowFollowCadenceTests {
    @Test func settlesAndWakesWithoutChangingAnimationClocks() {
        var cadence = WindowFollowCadence()
        #expect(cadence.mode == .idle)
        cadence.wake(at: 10)
        cadence.observe(.stationary, at: 10.3)
        #expect(cadence.mode == .tracking)
        cadence.observe(.stationary, at: 10.36)
        #expect(cadence.mode == .idle)
        cadence.observe(.changed, at: 11)
        cadence.observe(.changed, at: 11.2)
        cadence.observe(.stationary, at: 11.5)
        #expect(cadence.mode == .tracking)
        cadence.observe(.stationary, at: 11.56)
        #expect(cadence.mode == .idle)
        #expect(WindowFollowCadence.idleInterval <= 1.0 / 30)
    }

    @Test func missingHostClearsGraceAndExplicitEventsWakeImmediately() {
        var cadence = WindowFollowCadence()
        cadence.observe(.changed, at: 1)
        cadence.observe(.unavailable, at: 1.1)
        #expect(cadence.mode == .unavailable)
        cadence.observe(.stationary, at: 1.2)
        #expect(cadence.mode == .idle)
        cadence.wake(at: 2)
        #expect(cadence.mode == .tracking)
        cadence.observe(.stationary, at: 2.36)
        #expect(cadence.mode == .idle)
    }
}
