import AppKit
import SwiftUI
import Testing
@testable import PulseApp
@testable import PulseCore

@Suite("点数原生排版", .serialized) @MainActor struct CreditLayoutTests {
    @Test func nativeFontFitsEveryCapsuleWidth() {
        let balances = ["0.005", "0.019", "9.999", "99.999", "999.99", "1000", "60000", "60123",
                        "999999", "1250000", "999999999", "1" + String(repeating: "0", count: 100)]
        for raw in balances {
            for width in stride(from: 38.0, through: 156.0, by: 1) {
                let layout = CreditLabelLayout.fit(Decimal(string: raw)!, width: width)
                #expect(layout.measuredWidth <= width, "\(raw), \(width): \(layout.text)")
                #expect(layout.font.pointSize >= 12 && layout.font.pointSize <= 14)
                #expect(!layout.text.contains("…") && !layout.text.contains("\n"))
            }
        }
        #expect(CreditLabelLayout.fit(60000, width: 38).text == "60k")
        #expect(CreditLabelLayout.fit(60000, width: 156).text == "60k")
    }

    @Test func creditDemoDoesNotEmitConsumptionOrRecovery() {
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "credits-working")
        store.start(); defer { store.stop() }
        #expect(store.state.snapshot?.displayMode.creditBalance == Decimal(string: "60123.456"))
        #expect(store.working)
        #expect(store.consumptionSerial == 0 && store.recoverySerial == 0)
    }

    @Test func creditWorkingFlowHonorsMotionAndVisibility() throws {
        _ = NSApplication.shared
        let savedDefaults = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.credit-flow.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer { LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = savedDefaults }
        for reduceMotion in [false, true] {
            let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "credits-working")
            let model = OverlayModel(motionPreference: { reduceMotion })
            let overlay = OverlayController(store: store, model: model)
            defer { overlay.stop(); store.stop() }
            store.start(); overlay.show()
            #expect(model.working && model.consumptionDetected)
            #expect(model.consumptionAnimating == !reduceMotion)
            overlay.hide()
            #expect(!model.consumptionAnimating)
            overlay.show()
            #expect(model.consumptionAnimating == !reduceMotion)
        }
    }

    @Test func realRefreshSwitchesModesWithoutSyntheticFeedback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("synthetic-codex")
        let script = """
        #!/usr/bin/python3
        import sys,json,time
        reads=0
        reset=int(time.time())+3600
        for line in sys.stdin:
            m=json.loads(line)
            if 'id' not in m: continue
            result={}
            if m['method']=='account/read': result={'account':{'type':'chatgpt','email':'credits@example.invalid','planType':'pro'}}
            if m['method']=='account/rateLimits/read':
                reads+=1
                used=[99,100,100,0,1][min(reads-1,4)]
                result={'rateLimits':{'primary':{'usedPercent':used,'windowDurationMins':300,'resetsAt':reset+(3600 if reads>=4 else 0)},'credits':{'hasCredits':True,'unlimited':False,'balance':'60000'}}}
            print(json.dumps({'id':m['id'],'result':result}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = QuotaClient(executable: executable, timeoutSeconds: 5)
        client.stateRoot = directory.appendingPathComponent("state")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        for expectedCredits in [false, true, true, false, false] {
            store.refresh(manual: true)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while store.refreshing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(store.status == .ready)
            #expect((store.state.snapshot?.displayMode.creditBalance != nil) == expectedCredits)
            #expect(store.recoverySerial == 0)
        }
        // 只有最后一次同一订阅周期的真实消耗增加触发短反馈。
        #expect(store.consumptionSerial == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_CREDIT_DESKTOP"] != nil))
    func desktopCreditPreview() throws {
        _ = NSApplication.shared
        let savedDefaults = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.credit-desktop.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        let language = LanguageStore.shared.selection
        LanguageStore.shared.setSelection(.simplifiedChinese)
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "credits-working")
        // 此同步原生事件循环验证实际点击；关闭异步伸缩，动效由独立渲染 / 图层测试覆盖。
        let overlay = OverlayController(store: store, model: OverlayModel(motionPreference: { true }))
        defer {
            overlay.stop(); store.stop(); LanguageStore.shared.setSelection(language)
            LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = savedDefaults
        }
        NSApp.setActivationPolicy(.regular)
        store.start(); overlay.show()
        overlay.panel.title = "Codex Pulse · Credits synthetic preview"
        NSApp.activate()
        let timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
            MainActor.assumeIsolated {
                NSApp.stop(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(event, atStart: true)
                }
            }
        }
        NSApp.run()
        timer.invalidate()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_RENDER_CREDITS"] != nil))
    func renderNativeCreditStates() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PULSE_RENDER_CREDITS"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let oldDefaults = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.credit-render.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        let oldLanguage = LanguageStore.shared.selection, oldAppearance = NSApp.appearance
        defer {
            LanguageStore.shared.setSelection(oldLanguage); NSApp.appearance = oldAppearance
            LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = oldDefaults
        }
        for language in [PulseLanguage.simplifiedChinese, .english] {
            LanguageStore.shared.setSelection(language)
            for theme in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: theme)
                for scenario in ["credits", "credits-small", "credits-large", "credits-working", "credits-error", "credits-stale"] {
                    let store = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: scenario)
                    store.start(); defer { store.stop() }
                    for state in ["left", "right", "free", "details"] {
                        let model = OverlayModel(motionPreference: { true })
                        model.side = state == "left" ? .left : state == "right" ? .right : nil
                        model.blend = model.side == nil ? 0 : 1
                        model.width = state == "details" ? 280 : state == "free" ? 180 : 54
                        model.height = state == "details" ? 300 : 36
                        model.expanded = state == "details"; model.working = store.working
                        model.consumptionDetected = store.working
                        let host = NSHostingView(rootView: OverlayView(store: store, model: model))
                        host.sizingOptions = []
                        let panel = NSWindow(contentRect: CGRect(x: 100, y: 100, width: model.width + 32, height: model.height + 32),
                                             styleMask: [.borderless], backing: .buffered, defer: false)
                        panel.isOpaque = false; panel.backgroundColor = .clear; panel.contentView = host
                        panel.orderFrontRegardless(); defer { panel.orderOut(nil) }
                        try await Task.sleep(for: .milliseconds(160))
                        host.layoutSubtreeIfNeeded()
                        #expect(abs(host.bounds.width - (model.width + 32)) < 1)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent("\(language.rawValue)-\(theme == .aqua ? "light" : "dark")-\(scenario)-\(state).png"))
                    }
                }
            }
        }
    }
}
