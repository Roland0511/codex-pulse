import AppKit
import SwiftUI
import Testing
import PulseCore
@testable import PulseApp

@Suite("点数小数位偏好") @MainActor struct CreditDisplayStoreTests {
    @Test func defaultsPersistIndependentlyAndRejectInvalidValues() throws {
        let name = "pulse-credit-display-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: "appearance")
        let store = CreditDisplayStore(defaults: defaults)
        #expect(store.compactDecimalPlaces == 1)
        #expect(store.expandedDecimalPlaces == 2)
        store.setCompactDecimalPlaces(3)
        store.setExpandedDecimalPlaces(0)
        store.setCompactDecimalPlaces(-1)
        store.setExpandedDecimalPlaces(4)
        let restored = CreditDisplayStore(defaults: defaults)
        #expect(restored.compactDecimalPlaces == 3)
        #expect(restored.expandedDecimalPlaces == 0)
        #expect(defaults.string(forKey: "appearance") == "dark")
        defaults.set("invalid", forKey: "creditCompactDecimalPlaces")
        defaults.set(100, forKey: "creditExpandedDecimalPlaces")
        let invalid = CreditDisplayStore(defaults: defaults)
        #expect(invalid.compactDecimalPlaces == 1)
        #expect(invalid.expandedDecimalPlaces == 2)
        defaults.set(true, forKey: "creditExpandedDecimalPlaces")
        #expect(CreditDisplayStore(defaults: defaults).expandedDecimalPlaces == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_PRECISION_UI"] != nil))
    func nativePrecisionSettingsPreview() throws {
        _ = NSApplication.shared
        let name = "pulse-credit-precision-preview-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let originalDefaults = LocalDefaults.store, originalLanguage = LanguageStore.shared.selection
        LocalDefaults.store = defaults
        LanguageStore.shared.setSelection(.simplifiedChinese)
        let precision = CreditDisplayStore(defaults: defaults)
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "credits")
        store.start()
        defer {
            store.stop(); LanguageStore.shared.setSelection(originalLanguage)
            LocalDefaults.store = originalDefaults; defaults.removePersistentDomain(forName: name)
        }
        let compact = OverlayModel(motionPreference: { true }), hover = OverlayModel(motionPreference: { true })
        for model in [compact, hover] { model.side = .left; model.blend = 1; model.height = 36 }
        compact.width = 54; hover.width = 204
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PULSE_PRECISION_UI"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let finish: @MainActor () -> Void = {
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: true)
            }
        }
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
            Form { CreditPrecisionPreferences(creditDisplay: precision) }.formStyle(.grouped).frame(height: 240)
            HStack(spacing: 12) {
                OverlayView(store: store, model: compact, creditDisplay: precision).frame(width: 86, height: 68)
                OverlayView(store: store, model: hover, creditDisplay: precision).frame(width: 236, height: 68)
            }
            Button("完成预览", action: finish).padding(.leading, 20)
        }.frame(width: 440, height: 360).environment(\.locale, PulseText(language: .simplifiedChinese).locale))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 440, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "点数小数位 · 合成数据预览"; window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        let timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
            MainActor.assumeIsolated { finish() }
        }
        NSApp.run()
        timer.invalidate()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("precision-settings-final.png"))
        window.orderOut(nil)
    }
}
