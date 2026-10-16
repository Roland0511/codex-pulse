import AppKit
import PulseCore
import Testing
import SwiftUI
@testable import PulseApp

@MainActor private final class HostingTestWindows: CodexWindowSource {
    var isCodexActive = true
    var host: CodexWindow
    init() {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        // Leave room for the later translation on CI's smaller virtual display.
        // Screen-edge clipping has separate tests; this test expects an unclipped host.
        host = CodexWindow(id: 42, frame: CGRect(x: visible.minX + 60, y: visible.minY + 60,
            width: min(800, visible.width - 160), height: min(600, visible.height - 120)), isOnScreen: true)
    }
    func windows(matching id: CGWindowID?) -> [CodexWindow] { id == nil || id == host.id ? [host] : [] }
    func activate() {}
    func orderPanel(_ panel: PulsePanel, above window: CodexWindow, force: Bool) { if !panel.isVisible { panel.orderFrontRegardless() } }
}

@Suite("吸附内容与面板实际边缘", .serialized) @MainActor struct OverlayHostingTests {
    @Test func invisibleStatusIconNeverPushesRenderedContourPastDockAnchor() throws {
        _ = NSApplication.shared
        for scenario in ["normal", "stale", "unknown", "low", "credits", "credits-small", "credits-large"] {
            let store = QuotaStore(client: QuotaClient(), demo: true, demoScenario: scenario)
            defer { store.stop() }
            store.start()
            let model = OverlayModel(motionPreference: { true })
            model.width = DesignTokens.dockedWidth; model.side = .left; model.blend = 1
            let renderer = ImageRenderer(content: OverlayView(store: store, model: model).environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let row = image.height / 2
            let opaque = (0..<image.width).filter { bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0 > 0.9 }
            #expect(try #require(opaque.first) >= 15)
            #expect(try #require(opaque.last) <= 70)
        }
    }
    @Test func narrowTagExpansionCollapseAndHostTranslationKeepHostingBounds() async throws {
        _ = NSApplication.shared
        let old = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.hosting-tests.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer { LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = old }
        let source = HostingTestWindows()
        let store = QuotaStore(client: QuotaClient(), demo: true)
        let overlay = OverlayController(store: store, model: OverlayModel(motionPreference: { true }), windowSource: source)
        defer { overlay.stop(); store.stop() }
        store.start()
        for side in [DockSide.left, .right] {
            overlay.placeInCodex(side)
            for _ in 0..<3 {
                for expanded in [false, true, false] {
                    if expanded { overlay.open() } else { overlay.close() }
                    // SwiftUI/AppKit layout must settle without changing the requested panel size.
                    try await Task.sleep(for: .milliseconds(30))
                    overlay.panel.contentView?.layoutSubtreeIfNeeded()
                    let container = try #require(overlay.panel.contentView as? PanelMaskContainer)
                    #expect(container.hosting.frame == container.bounds)
                    #expect(abs(overlay.panel.frame.width - overlay.model.width - 32) < 0.01)
                    let body = overlay.panel.frame.insetBy(dx: 16, dy: 16)
                    #expect(abs((side == .left ? body.minX - source.host.frame.minX : body.maxX - source.host.frame.maxX)) < 0.01)
                }
            }
            let before = overlay.panel.frame
            source.host = CodexWindow(id: 42, frame: source.host.frame.offsetBy(dx: 47, dy: 23), isOnScreen: true)
            overlay.syncCodexWindow()
            #expect(overlay.panel.frame == before.offsetBy(dx: 47, dy: 23))
        }
    }
}
