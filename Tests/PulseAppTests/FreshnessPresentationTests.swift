import AppKit
import SwiftUI
import Testing
@testable import PulseApp
@testable import PulseCore

@Suite("紧凑胶囊数据状态", .serialized) @MainActor struct FreshnessPresentationTests {
    // 仅使用合成数据；截图不证明真实锁屏 / 休眠恢复。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_RENDER_FRESHNESS"] != nil))
    func renderCompactWarningsWithoutChangingCapsuleGeometry() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PULSE_RENDER_FRESHNESS"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let oldLanguage = LanguageStore.shared.selection, oldAppearance = NSApp.appearance
        defer { LanguageStore.shared.setSelection(oldLanguage); NSApp.appearance = oldAppearance }
        for language in [PulseLanguage.simplifiedChinese, .english] {
            LanguageStore.shared.setSelection(language)
            for theme in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: theme)
                for scenario in ["normal", "stale", "error", "credits-stale", "credits-error", "logout", "loading"] {
                    let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: scenario)
                    store.start(); defer { store.stop() }
                    for side in [DockSide.left, .right] {
                        let model = OverlayModel(motionPreference: { true })
                        model.side = side; model.blend = 1
                        model.width = DesignTokens.dockedWidth
                        let host = NSHostingView(rootView: OverlayView(store: store, model: model))
                        host.sizingOptions = []
                        let size = NSSize(width: DesignTokens.dockedWidth + 32, height: DesignTokens.height + 32)
                        let panel = NSWindow(contentRect: CGRect(origin: CGPoint(x: 120, y: 120), size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
                        panel.isOpaque = false; panel.backgroundColor = .clear; panel.contentView = host
                        panel.orderFrontRegardless(); defer { panel.orderOut(nil) }
                        try await Task.sleep(for: .milliseconds(100))
                        host.layoutSubtreeIfNeeded()
                        #expect(host.bounds.size == size)
                        #expect(model.width == 54 && model.height == 36)
                        #expect(store.client.requestCount == 0)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        let name = "\(language.rawValue)-\(theme == .aqua ? "light" : "dark")-\(scenario)-\(side.rawValue).png"
                        try png.write(to: output.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}
