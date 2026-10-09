import Testing
import AppKit
@testable import PulseApp
@testable import PulseCore

@Suite("固定吸附长条") @MainActor struct OverlayTests {
    @Test func pinSurvivesMouseLeaveAndOnlyAffectsDockedWidth() {
        let model = OverlayModel()
        #expect(model.compactWidth == DesignTokens.capsuleWidth)
        model.side = .left
        #expect(model.compactWidth == DesignTokens.dockedWidth)
        model.hovered = true
        #expect(model.compactWidth == DesignTokens.dockedExpandedWidth)
        model.pinned = true; model.hovered = false
        #expect(model.compactWidth == DesignTokens.dockedExpandedWidth)
        model.side = .right
        #expect(model.compactWidth == DesignTokens.dockedExpandedWidth)
        model.side = nil
        #expect(model.compactWidth == DesignTokens.capsuleWidth)
        model.side = .left; model.pinned = false
        #expect(model.compactWidth == DesignTokens.dockedWidth)
    }
    @Test func workContinuesPastShortBurstAndRestartsAfterShow() async throws {
        _ = NSApplication.shared
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "working")
        let model = OverlayModel(motionPreference: { false })
        let overlay = OverlayController(store: store, model: model)
        defer { store.stop(); overlay.stop() }
        store.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.working && model.consumptionDetected && model.consumptionAnimating)
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        try await Task.sleep(for: .milliseconds(3400))
        #expect(updates == 0) // 流光不能每帧使整个胶囊模型失效。
        withExtendedLifetime(subscription) {}
        #expect(model.consumptionDetected && model.consumptionAnimating)
        overlay.hide(); #expect(!model.consumptionAnimating && !model.consumptionDetected)
        overlay.show(); #expect(model.consumptionDetected)
        store.suspend(); try await Task.sleep(for: .milliseconds(100))
        #expect(!model.consumptionAnimating && !model.consumptionDetected)
    }
    @Test func reducedMotionShowsWorkWithoutAnimatedTrace() async throws {
        _ = NSApplication.shared
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "working")
        let model = OverlayModel(motionPreference: { true })
        let overlay = OverlayController(store: store, model: model)
        defer { store.stop(); overlay.stop() }
        store.start(); try await Task.sleep(for: .milliseconds(100))
        #expect(model.consumptionDetected && model.working && !model.consumptionAnimating)
        #expect(model.consumptionMessage == "Codex 工作中")
    }
    @Test func confirmedBurstExpiresWithoutContinuousWork() async throws {
        _ = NSApplication.shared
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "consuming")
        let model = OverlayModel(motionPreference: { false })
        let overlay = OverlayController(store: store, model: model)
        defer { store.stop(); overlay.stop() }
        store.start(); try await Task.sleep(for: .milliseconds(100))
        #expect(model.consumptionDetected && model.consumptionAnimating && !model.working)
        try await Task.sleep(for: .milliseconds(3400))
        #expect(!model.consumptionDetected && !model.consumptionAnimating)
    }
}
