import AppKit
import Testing
@testable import PulseApp
@testable import PulseCore

@MainActor private final class FakeCodexWindows: CodexWindowSource {
    var isCodexActive = true
    var items = [CodexWindow(id: 42, frame: CGRect(x: 100, y: 100, width: 800, height: 600), isOnScreen: true)]
    var activations = 0
    func windows(matching id: CGWindowID?) -> [CodexWindow] { items.filter { id == nil || $0.id == id } }
    func activate() { activations += 1; isCodexActive = true }
}

@Suite("Codex 窗口吸附生命周期", .serialized) @MainActor struct WindowDockingTests {
    @Test func followsHidesRecoversAndReturnsToScreenDocking() throws {
        _ = NSApplication.shared
        let original = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.window-tests.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer { LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = original }
        let source = FakeCodexWindows()
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true)
        let overlay = OverlayController(store: store, model: OverlayModel(motionPreference: { true }), windowSource: source)
        defer { overlay.stop(); store.stop() }
        overlay.place(.left)
        let screenPreference = LocalDefaults.store.data(forKey: "overlayPosition")
        overlay.placeInCodex(.right)
        #expect(source.activations == 1 && overlay.windowDock?.side == .right)
        #expect(overlay.panel.isVisible)
        let before = overlay.panel.frame
        source.items = [CodexWindow(id: 42, frame: source.items[0].frame.offsetBy(dx: 50, dy: 70), isOnScreen: true)]
        overlay.syncCodexWindow()
        #expect(overlay.panel.frame == before.offsetBy(dx: 50, dy: 70))
        overlay.open()
        #expect(overlay.panel.frame.maxX == before.maxX + 50)
        overlay.close()
        #expect(LocalDefaults.store.data(forKey: "overlayPosition") == screenPreference)
        source.items = [CodexWindow(id: 42, frame: source.items[0].frame, isOnScreen: false)]
        overlay.syncCodexWindow()
        #expect(!overlay.panel.isVisible && overlay.attachedWindow?.id == 42)
        source.items = [CodexWindow(id: 42, frame: source.items[0].frame, isOnScreen: true)]
        overlay.syncCodexWindow()
        #expect(overlay.panel.isVisible)
        source.isCodexActive = false; overlay.syncCodexWindow()
        #expect(!overlay.panel.isVisible)
        source.isCodexActive = true; overlay.syncCodexWindow()
        #expect(overlay.panel.isVisible)
        overlay.hide(); overlay.syncCodexWindow()
        #expect(!overlay.panel.isVisible)
        overlay.show(); #expect(overlay.panel.isVisible)
        source.items = []; overlay.syncCodexWindow()
        #expect(!overlay.panel.isVisible && overlay.windowDock != nil)
        source.items = [CodexWindow(id: 80, frame: CGRect(x: 100, y: 100, width: 700, height: 500), isOnScreen: true)]
        overlay.syncCodexWindow()
        #expect(overlay.attachedWindow?.id == 80 && overlay.panel.isVisible)
        overlay.place(.left)
        #expect(overlay.windowDock == nil && overlay.attachedWindow == nil)
        #expect(LocalDefaults.store.data(forKey: "codexWindowDock") == nil)
        #expect(overlay.panel.isVisible && overlay.model.side == .left)
    }

    @Test func overlappingTargetsUseTheChoiceAndEscapeStaysFree() throws {
        _ = NSApplication.shared
        let original = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.window-tests.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer { LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = original }
        let source = FakeCodexWindows()
        let screen = try #require(NSScreen.main).visibleFrame
        source.items = [CodexWindow(id: 42, frame: screen, isOnScreen: true)]
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true)
        let model = OverlayModel(motionPreference: { true })
        let overlay = OverlayController(store: store, model: model, windowSource: source)
        defer { overlay.stop(); store.stop() }
        let choices: [DockDestination?] = [.screen, .codex, nil]
        for (choice, offset) in choices.flatMap({ choice in [10.0, 90.0].map { (choice, $0) } }) {
            overlay.place(nil)
            var prompts = 0
            overlay.dockTargetChooser = { screenSide, windowSide in
                #expect(screenSide == .left && windowSide == .left)
                prompts += 1; return choice
            }
            let body = overlay.panel.frame.insetBy(dx: 16, dy: 16)
            model.dragBegan?(CGPoint(x: body.midX, y: body.midY))
            model.dragMoved?(CGPoint(x: screen.minX + offset, y: screen.midY))
            #expect(model.side == nil) // Ambiguous drag never preselects a host.
            model.dragEnded?()
            #expect(prompts == 1)
            switch choice {
            case .screen:
                #expect(overlay.windowDock == nil && model.side == .left)
                #expect(overlay.panel.collectionBehavior.contains(.fullScreenNone))
            case .codex: #expect(overlay.windowDock?.side == .left)
            case nil:
                #expect(overlay.windowDock == nil && model.side == nil)
                #expect(overlay.panel.collectionBehavior.contains(.fullScreenNone))
            }
        }
    }

    @Test func unavailableWindowDoesNotEnableOrChangePlacement() throws {
        _ = NSApplication.shared
        let original = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.window-tests.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer { LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = original }
        let source = FakeCodexWindows(); source.items = []
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true)
        let overlay = OverlayController(store: store, windowSource: source)
        defer { overlay.stop(); store.stop() }
        #expect(!overlay.canDockToCodex)
        overlay.placeInCodex(.left)
        #expect(overlay.windowDock == nil && source.activations == 0)
    }
}
