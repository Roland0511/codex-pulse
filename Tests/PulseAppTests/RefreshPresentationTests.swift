import AppKit
import Combine
import SwiftUI
import Testing
@testable import PulseApp
@testable import PulseCore

@Suite("后台刷新展示", .serialized) @MainActor struct RefreshPresentationTests {
    private func fixture(credits: Bool, delay: Double) throws -> (QuotaStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("synthetic-refresh")
        let script = """
        #!/usr/bin/python3
        import json,sys,time
        from pathlib import Path
        counter=Path(__file__).with_suffix('.reads')
        reads=int(counter.read_text()) if counter.exists() else 0
        for line in sys.stdin:
            m=json.loads(line)
            if 'id' not in m: continue
            result={}
            if m['method']=='account/read':
                result={'account':{'type':'chatgpt','email':'refresh@example.invalid','planType':'pro'}}
            if m['method']=='account/rateLimits/read':
                reads+=1
                counter.write_text(str(reads))
                print(json.dumps({'method':'account/updated','params':{'authMode':'chatgpt'}}),flush=True)
                if reads>1:time.sleep(\(delay))
                result={'rateLimits':{'primary':{'usedPercent':100 if \(credits ? "True" : "False") else 18+reads,'windowDurationMins':300,'resetsAt':1894057200}}}
                if \(credits ? "True" : "False"):
                    result['rateLimits']['credits']={'balance':str(62000-reads*1000),'hasCredits':True,'unlimited':False}
            print(json.dumps({'id':m['id'],'result':result}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = QuotaClient(executable: executable, timeoutSeconds: 5)
        client.stateRoot = directory.appendingPathComponent("state")
        return (QuotaStore(client: client), directory)
    }

    private func settle(_ store: QuotaStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while store.refreshing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.refreshing && store.status == .ready)
    }

    @Test(arguments: [false, true])
    func slowRefreshRetainsConfirmedValues(_ credits: Bool) async throws {
        let (store, directory) = try fixture(credits: credits, delay: 0.4)
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.refresh(); try await settle(store)
        let before = try #require(store.state.snapshot)
        var missingSnapshot = false
        let observation = store.$state.sink { if $0.snapshot == nil { missingSnapshot = true } }
        defer { observation.cancel() }
        store.refresh(manual: true)
        try await Task.sleep(for: .milliseconds(180))
        #expect(store.refreshing && store.status == .ready)
        #expect(store.state.snapshot == before)
        try await settle(store)
        #expect(!missingSnapshot)
        #expect(store.state.snapshot != before)
        if credits { #expect(store.state.snapshot?.displayMode.creditBalance == 60000) }
        else { #expect(store.state.snapshot?.selectedWindow?.remainingPercent == 80) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_RENDER_REFRESH"] != nil))
    func renderRefreshStates() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PULSE_RENDER_REFRESH"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = LocalDefaults.store, language = LanguageStore.shared.selection
        let suite = "dev.roland.codex-pulse.refresh-render.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer {
            LanguageStore.shared.setSelection(language)
            LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = defaults
        }
        LanguageStore.shared.setSelection(.simplifiedChinese)
        for credits in [false, true] {
            for width in [54.0, 180.0, 280.0] {
                for reduced in [false, true] {
                    let (store, directory) = try fixture(credits: credits, delay: 0.5)
                    defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
                    store.refresh(); try await settle(store)
                    let model = OverlayModel(motionPreference: { reduced })
                    model.width = width; model.height = width == 280 ? 280 : 36
                    model.expanded = width == 280
                    let host = NSHostingView(rootView: OverlayView(store: store, model: model))
                    host.sizingOptions = []
                    let panel = NSWindow(contentRect: CGRect(x: 160, y: 160, width: width+32, height: model.height+32),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.contentView = host; panel.orderFrontRegardless()
                    defer { panel.orderOut(nil) }
                    try await Task.sleep(for: .milliseconds(100))
                    let originalBounds = host.bounds
                    let prefix = "\(credits ? "credits" : "percent")-\(Int(width))-\(reduced ? "static" : "motion")"
                    func capture(_ name: String) throws {
                        host.layoutSubtreeIfNeeded()
                        #expect(host.bounds == originalBounds)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(prefix+"-"+name+".png"))
                    }
                    try capture("before")
                    let before = store.state.snapshot
                    store.client.stop() // 冷重连也必须保留已有数据。
                    store.refresh(manual: true)
                    try await Task.sleep(for: .milliseconds(150))
                    #expect(store.state.snapshot == before && store.refreshing)
                    try capture("pending")
                    try await settle(store)
                    try await Task.sleep(for: .milliseconds(420))
                    try capture("after")
                }
            }
        }
    }

}
