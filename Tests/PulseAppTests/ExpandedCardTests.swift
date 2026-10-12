import AppKit
import SwiftUI
import Testing
@testable import PulseApp
@testable import PulseCore

@Suite("展开额度卡片", .serialized) @MainActor struct ExpandedCardTests {
    @Test func defaultBucketIsNamedOnceAndUnknownRemainsUnknown() {
        let text = PulseText(language: .simplifiedChinese)
        let window = QuotaWindow(bucketID: "codex", slot: "primary", usedPercent: 22,
                                 durationMinutes: 10080, resetsAt: nil)
        #expect(window.detailName(using: text) == "7天额度")
        let named = QuotaWindow(bucketID: "codex", bucketName: "Review", slot: "primary",
                                usedPercent: nil, durationMinutes: nil, resetsAt: nil)
        #expect(named.detailName(using: text) == "Review · 周期未知")
        #expect(QuotaText.percentage(named.remainingPercent, using: text) == "未知")
    }

    @Test func livePanelMeasuresWorkingContentWithoutAnUnnecessaryScroller() async throws {
        _ = NSApplication.shared
        let defaults = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.layout-tests.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer {
            LocalDefaults.store.removePersistentDomain(forName: suite)
            LocalDefaults.store = defaults
        }
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "working")
        let model = OverlayModel(motionPreference: { true })
        let overlay = OverlayController(store: store, model: model)
        defer { store.stop(); overlay.stop() }
        store.start(); overlay.open(keyboard: true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.expanded)
        #expect(model.width == DesignTokens.detailsWidth)
        #expect(model.detailsIdealHeight > 0)
        #expect(model.height >= model.detailsIdealHeight - 1)
        let content = try #require(overlay.panel.contentView)
        #expect(descendants(content).compactMap { $0 as? NSScrollView }.isEmpty)
        overlay.close()
        #expect(!model.expanded)
        #expect(model.height == DesignTokens.height)
    }

    // 显式启用的原生渲染验收；只用合成数据，不读取账户或启动真实 CLI。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_RENDER_CARDS"] != nil))
    func renderNativeStates() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PULSE_RENDER_CARDS"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let savedDefaults = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.card-tests.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        let oldLanguage = LanguageStore.shared.selection
        let oldAppearance = NSApp.appearance
        defer {
            LanguageStore.shared.setSelection(oldLanguage); NSApp.appearance = oldAppearance
            LocalDefaults.store.removePersistentDomain(forName: suite)
            LocalDefaults.store = savedDefaults
        }
        for language in [PulseLanguage.simplifiedChinese, .english] {
            LanguageStore.shared.setSelection(language)
            for theme in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: theme)
                for scenario in ["single", "dual", "long", "unknown", "loading", "error", "stale", "working"] {
                    let (store, directory) = try fixture(scenario)
                    defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
                    if store.demo { store.start() } else {
                        store.refresh()
                        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                        while store.refreshing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                        #expect(store.status == .ready)
                    }
                    let model = OverlayModel(motionPreference: { true })
                    model.expanded = true
                    model.width = DesignTokens.detailsWidth
                    model.height = scenario == "long" ? 320 : scenario == "dual" ? 250 : 190
                    model.working = scenario == "working"
                    model.consumptionDetected = model.working
                    var measured = 0.0
                    model.detailsSizeChanged = { measured = $0 }
                    let host = NSHostingView(rootView: OverlayView(store: store, model: model))
                    let panel = NSWindow(contentRect: CGRect(x: 120, y: 120, width: model.width + 32, height: model.height + 32),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.title = "Codex Pulse · Card preview"
                    panel.backgroundColor = .clear; panel.isOpaque = false
                    panel.contentView = host; panel.orderFrontRegardless()
                    defer { panel.orderOut(nil) }
                    try await Task.sleep(for: .milliseconds(140))
                    if scenario != "long", measured > 0 {
                        model.height = max(DesignTokens.detailsSingleWindowHeight, measured)
                        panel.setContentSize(NSSize(width: model.width + 32, height: model.height + 32))
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    host.layoutSubtreeIfNeeded()
                    let scrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter { !$0.isHidden && $0.frame.height > 0 }
                    if scenario == "single" || scenario == "dual" || scenario == "working" {
                        #expect(scrolls.isEmpty, "正常卡片不应创建滚动容器")
                    }
                    if scenario == "long" { #expect(!scrolls.isEmpty, "长列表仍须可滚动") }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "\(language.rawValue)-\(theme == .aqua ? "light" : "dark")-\(scenario).png"
                    try png.write(to: output.appendingPathComponent(name))
                }
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func fixture(_ scenario: String) throws -> (QuotaStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard scenario == "single" || scenario == "dual" else {
            return (QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: scenario), directory)
        }
        let executable = directory.appendingPathComponent("synthetic-codex")
        let script = """
        #!/usr/bin/python3
        import sys,json,time
        for line in sys.stdin:
            m=json.loads(line)
            if 'id' not in m: continue
            result={}
            if m['method']=='account/read': result={'account':{'type':'chatgpt','email':'card@example.invalid','planType':'pro'}}
            if m['method']=='account/rateLimits/read':
                bucket={'primary':{'usedPercent':22,'windowDurationMins':10080,'resetsAt':int(time.time())+5*86400}}
                if '\(scenario)'=='dual': bucket['secondary']={'usedPercent':9,'windowDurationMins':300,'resetsAt':int(time.time())+10800}
                result={'rateLimits':bucket,'rateLimitResetCredits':{'availableCount':0}}
            print(json.dumps({'id':m['id'],'result':result}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = QuotaClient(executable: executable, timeoutSeconds: 5)
        client.stateRoot = directory.appendingPathComponent("state")
        return (QuotaStore(client: client), directory)
    }
}
