import AppKit
import Foundation
import PulseCore
import SwiftUI
import Testing
@testable import PulseApp

@Suite("TPS 接入、设置与原生布局", .serialized) @MainActor struct ThroughputStoreTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
    @Test func trustedSessionSelectionWaitingParallelDisconnectAndPreferences() async throws {
        let suite = "pulse-tps-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let id = "11111111-1111-4111-8111-111111111111", turn = "turn"
        let date = Date(), end = Int64(date.timeIntervalSince1970 * 1000) - 100
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: date), "payload": payload]); data.append(10); return data
        }
        var bytes = try line("event_msg", ["type": "task_started", "turn_id": turn])
        bytes.append(try line("event_msg", ["type": "item_completed", "turn_id": turn,
            "item": ["id": "item", "type": "Reasoning", "text": "DO NOT KEEP"], "started_at_ms": end - 1000, "completed_at_ms": end]))
        bytes.append(try line("token_usage_record", ["turn_id": turn, "thread_id": id, "response_id": "response", "usage": ["output_tokens": 82]]))
        let file = root.appendingPathComponent("rollout-fixture-" + id + ".jsonl")
        try bytes.write(to: file, options: .atomic)
        let tps = ThroughputStore(defaults: defaults, root: root), activity = ActivityStore(alive: { _ in true })
        defer { tps.stop(); activity.stop() }
        tps.bind(activity)
        #expect(tps.enabled && tps.presentation.phase == .disconnected)
        let owner = try #require(ActivityOwner.read(getpid()))
        func signal(_ event: ActivityEvent, session: String = id, tool: String? = nil) -> ActivitySignal {
            .init(event: event, session: ActivitySignal.hash(session), turn: ActivitySignal.hash(turn),
                  tool: tool.map(ActivitySignal.hash), time: Date().timeIntervalSince1970, owner: owner)
        }
        activity.receive(signal(.start)); #expect(tps.presentation.phase == .disconnected)
        activity.setVerified(true)
        try await wait { tps.presentation.sample?.tokensPerSecond == 82 }
        #expect(tps.presentation.phase == .measured || tps.presentation.phase == .retained)
        let measured = tps.presentation
        tps.setLayout(.stacked); #expect(tps.presentation == measured)
        tps.setLayout(.horizontal); #expect(tps.presentation == measured)
        if let output = ProcessInfo.processInfo.environment["PULSE_TPS_UI"] {
            try await nativePreview(tps: tps, activity: activity, defaults: defaults, output: URL(fileURLWithPath: output), signal: signal)
            return
        }
        activity.receive(signal(.waiting, tool: "permission"))
        try await wait { tps.presentation.phase == .waiting && tps.presentation.sample != nil }
        activity.receive(signal(.start, session: "22222222-2222-4222-8222-222222222222"))
        #expect(tps.presentation.phase == .parallel && tps.presentation.sample == nil && tps.presentation.sessions == 2)
        activity.receive(signal(.stop, session: "22222222-2222-4222-8222-222222222222"))
        try await wait { tps.presentation.phase == .waiting }
        activity.receive(signal(.afterTool, tool: "permission"))
        try await wait { tps.presentation.sample != nil }
        tps.setPaused(true); #expect(tps.presentation.phase == .paused && tps.presentation.sample == nil)
        tps.setPaused(false); try await wait { tps.presentation.sample != nil }
        tps.setHidden(true); #expect(tps.presentation.phase == .paused)
        tps.setHidden(false); try await wait { tps.presentation.sample != nil }
        try FileManager.default.removeItem(at: file)
        try await wait { tps.presentation.phase == .unavailable }
        #expect(tps.presentation.sample == nil)
        activity.setVerified(false); #expect(tps.presentation.phase == .disconnected)
        tps.setEnabled(false); #expect(!ThroughputStore(defaults: defaults, root: root).enabled)
        tps.setEnabled(true); #expect(ThroughputStore(defaults: defaults, root: root).enabled)
    }
    private func nativePreview(tps: ThroughputStore, activity: ActivityStore, defaults: UserDefaults,
                               output: URL, signal: @escaping (ActivityEvent, String, String?) -> ActivitySignal) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let old = LocalDefaults.store, language = LanguageStore.shared.selection
        LocalDefaults.store = defaults; LanguageStore.shared.setSelection(.simplifiedChinese)
        defer { LocalDefaults.store = old; LanguageStore.shared.setSelection(language) }
        let quota = QuotaStore(client: QuotaClient(executable: nil), demo: true, demoScenario: "credits", throughput: tps)
        quota.start()
        let precision = CreditDisplayStore(defaults: defaults)
        let controller = OverlayController(store: quota, model: OverlayModel(motionPreference: { true }))
        defer { controller.stop(); quota.stop() }
        controller.place(.right); controller.show()
        let id = "11111111-1111-4111-8111-111111111111", second = "22222222-2222-4222-8222-222222222222"
        var permission = "permission", secondaryTurn: String?
        func secondary(_ event: ActivityEvent, turn: String) {
            let base = signal(event, second, nil)
            activity.receive(.init(event: event, session: base.session, turn: ActivitySignal.hash(turn),
                                   time: Date().timeIntervalSince1970, owner: base.owner))
        }
        func single() {
            activity.setVerified(true)
            if let turn = secondaryTurn { secondary(.stop, turn: turn); secondaryTurn = nil }
            activity.receive(signal(.start, id, nil))
            activity.receive(signal(.afterTool, id, permission))
        }
        var finished = false
        let finish: @MainActor () -> Void = { finished = true }
        let compact = OverlayModel(motionPreference: { true }), hover = OverlayModel(motionPreference: { true }), detail = OverlayModel(motionPreference: { true })
        for model in [compact, hover, detail] { model.throughputEnabled = true; model.side = .left; model.blend = 1 }
        compact.width = 104; hover.width = 204; detail.width = 280; detail.height = 368; detail.expanded = true
        let sizes = tps.$enabled.sink { enabled in
            compact.throughputEnabled = enabled; compact.width = enabled && tps.layout == .horizontal ? 104 : 54
            hover.throughputEnabled = enabled; detail.throughputEnabled = enabled
        }
        let layouts = tps.$layout.sink { layout in
            compact.throughputLayout = layout
            compact.width = tps.enabled && layout == .horizontal ? 104 : 54
            hover.throughputLayout = layout; detail.throughputLayout = layout
        }
        defer { sizes.cancel(); layouts.cancel() }
        let host = NSHostingView(rootView: HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 12) {
            Form {
                ThroughputPreferences(throughput: tps)
                CreditPrecisionPreferences(creditDisplay: precision)
            }.formStyle(.grouped).frame(height: 365)
            Text("合成账户与计时；屏幕右侧为实际胶囊面板").font(.caption).padding(.horizontal, 20)
            HStack {
                Button("单会话") { single() }
                Button("等待许可") { single(); permission = UUID().uuidString; activity.receive(signal(.waiting, id, permission)) }
                Button("并行会话") { single(); let turn = UUID().uuidString; secondaryTurn = turn; secondary(.start, turn: turn) }
                Button("断开") { activity.setVerified(false) }
            }.padding(.horizontal, 20)
            HStack {
                Button("展开详情") { controller.open(keyboard: true) }
                Button("收起") { controller.close() }
                Button("完成预览", action: finish)
            }.padding(.horizontal, 20)
          }.padding(.bottom, 16).frame(width: 500)
          VStack(alignment: .leading, spacing: 8) {
              OverlayView(store: quota, model: compact, creditDisplay: precision).frame(width: 136, height: 68)
              OverlayView(store: quota, model: hover, creditDisplay: precision).frame(width: 236, height: 68)
              OverlayView(store: quota, model: detail, creditDisplay: precision).frame(width: 312, height: 400)
          }
        }.frame(width: 824).environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: CGRect(x: 250, y: 220, width: 824, height: 552),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TPS 布局 · 合成数据验收"; window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate()
        // Native control/geometry acceptance only. Async data lifecycle is exercised separately
        // above/below this opt-in preview, outside NSApp's nested blocking test loop.
        let timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in MainActor.assumeIsolated { finish() } }
        let stop: @MainActor () -> Void = {
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
        }
        let monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { if finished { stop() } } }
        NSApp.run(); timer.invalidate(); monitor.invalidate()
        window.orderOut(nil)
    }
    @Test func layoutDefaultsPersistAndInvalidValuesFallBackWithoutChangingTPS() throws {
        let suite = "pulse-tps-layout-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThroughputStore(defaults: defaults)
        defer { store.stop() }
        #expect(store.layout == .horizontal && store.enabled)
        store.setLayout(.stacked)
        let restored = ThroughputStore(defaults: defaults)
        defer { restored.stop() }
        #expect(restored.layout == .stacked)
        store.setEnabled(false); store.setEnabled(true)
        #expect(store.layout == .stacked)
        defaults.set("unknown", forKey: "throughputLayout")
        let invalid = ThroughputStore(defaults: defaults)
        defer { invalid.stop() }
        #expect(invalid.layout == .horizontal)
    }
    @Test func toggleResizesActualDockedPanelAndKeepsItsAnchor() async throws {
        _ = NSApplication.shared
        let suite = "pulse-tps-geometry-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)), old = LocalDefaults.store
        LocalDefaults.store = defaults
        defer { LocalDefaults.store = old; defaults.removePersistentDomain(forName: suite) }
        let tps = ThroughputStore(defaults: defaults)
        let quota = QuotaStore(client: QuotaClient(executable: nil), demo: true, throughput: tps)
        let model = OverlayModel(motionPreference: { true })
        let controller = OverlayController(store: quota, model: model)
        defer { quota.stop(); controller.stop() }
        quota.start()
        for side in [DockSide.left, .right] {
            controller.place(side)
            #expect(model.width == 104)
            let before = controller.panel.frame
            tps.setEnabled(false); #expect(model.width == 54)
            let after = controller.panel.frame
            #expect(abs((side == .left ? before.minX - after.minX : before.maxX - after.maxX)) < 0.1)
            tps.setEnabled(true); #expect(model.width == 104)
            tps.setLayout(.stacked); #expect(model.width == 54)
            let stacked = controller.panel.frame
            #expect(abs((side == .left ? before.minX - stacked.minX : before.maxX - stacked.maxX)) < 0.1)
            model.hovered = true; #expect(model.compactWidth == 204); model.hovered = false
            model.pinned = true; #expect(model.compactWidth == 204); model.pinned = false
            controller.open(); #expect(model.width == 280)
            controller.close(); #expect(model.width == 54)
            tps.setLayout(.horizontal); #expect(model.width == 104)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_TPS_RENDER"] != nil))
    func nativeThroughputStateRenders() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PULSE_TPS_RENDER"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousLanguage = LanguageStore.shared.selection, previousAppearance = AppearanceStore.shared.selection
        defer { LanguageStore.shared.setSelection(previousLanguage); AppearanceStore.shared.setSelection(previousAppearance) }
        for language in [PulseLanguage.simplifiedChinese, .english] {
            LanguageStore.shared.setSelection(language)
            for theme in ["light", "dark"] {
                AppearanceStore.shared.setSelection(theme)
                let sample = ThroughputSample(tokensPerSecond: 82, recordedAt: Date(), turn: "synthetic")
                let previews = ThroughputPhase.allCasesForPreview.map { phase in
                    ThroughputPresentation(phase: phase, sample: [.measured, .retained, .waiting].contains(phase) ? sample : nil, sessions: phase == .parallel ? 2 : 1)
                }
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, preview in
                        HStack(spacing: 16) {
                            Text(preview.phase.rawValue).font(.system(size: 12)).frame(width: 90, alignment: .leading)
                            HStack(spacing: 5) {
                                Text("60.1k").font(.system(size: 12, weight: .medium, design: .rounded))
                                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 14)
                                ThroughputInline(presentation: preview, narrow: true).frame(width: 37, alignment: .trailing)
                            }.padding(.horizontal, 8).frame(width: 104, height: 36)
                                .background(AppearanceStore.shared.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                            VStack(spacing: 0) {
                                Text("60.1k").font(.system(size: 12, weight: .medium, design: .rounded)).frame(height: 14)
                                ThroughputInline(presentation: preview, narrow: true, stacked: true).frame(width: 38, height: 10)
                            }.frame(width: 54, height: 36)
                                .background(AppearanceStore.shared.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.padding(20).frame(width: 390).background(AppearanceStore.shared.palette.track)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light))
                let size = host.fittingSize
                host.frame = CGRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("tps-\(language.rawValue)-\(theme).png"))
            }
        }
    }
}
private extension ThroughputPhase {
    static var allCasesForPreview: [Self] { [.measured, .retained, .sampling, .waiting, .parallel, .idle, .disconnected, .unavailable, .paused] }
}
