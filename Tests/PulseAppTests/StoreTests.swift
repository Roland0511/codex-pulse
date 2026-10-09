import Foundation
import Testing
@testable import PulseApp
@testable import PulseCore

@Suite("刷新合并与账户隔离", .serialized) @MainActor struct StoreTests {
    private func fake(_ mode: String) throws -> (QuotaStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import sys,json,time
        reads=0; quotas=0
        for line in sys.stdin:
            m=json.loads(line)
            if 'id' not in m: continue
            result={}
            if m['method']=='account/read':
                reads+=1
                switching = '\(mode)' in ['switch','notify-switch']
                boundary = 4 if '\(mode)'=='notify-switch' else 3
                email='a@example.invalid' if not switching or reads<boundary else 'b@example.invalid'
                result={'account':{'type':'chatgpt','email':email,'planType':'pro'}}
            elif m['method']=='account/rateLimits/read':
                quotas+=1
                if '\(mode)'=='notify-switch' and quotas==2:
                    print(json.dumps({'method':'account/updated','params':{}}),flush=True)
                time.sleep(0.1)
                if '\(mode)'=='failure' and quotas>1:
                    print(json.dumps({'id':m['id'],'error':{'code':503,'message':'unavailable'}}),flush=True);continue
                used=30+quotas if '\(mode)'=='consume' else 30
                result={'rateLimits':{'primary':{'usedPercent':used,'windowDurationMins':120,'resetsAt':1894057200}}}
            print(json.dumps({'id':m['id'],'result':result}),flush=True)
            if m['method']=='initialize' and '\(mode)'=='startup-notify':
                print(json.dumps({'method':'account/updated','params':{}}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (QuotaStore(client: QuotaClient(executable: executable, timeoutSeconds: 5)), directory)
    }
    private func settled(_ store: QuotaStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while store.refreshing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.refreshing)
    }
    @Test func concurrentManualAndAutomaticRefreshCoalesce() async throws {
        let (store, directory) = try fake("normal")
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.refresh()
        for _ in 0..<20 { store.refresh(manual: true); store.opened() }
        try await settled(store)
        #expect(store.client.quotaReadCount == 1)
        #expect(store.state.snapshot?.selectedWindow?.remainingPercent == 70)
        store.suspend(); store.refresh(manual: true)
        #expect(store.client.quotaReadCount == 1)
        store.resume(); try await settled(store)
        #expect(store.client.quotaReadCount == 2)
    }
    @Test func failurePreservesAndMarksCacheThenResumeRevalidates() async throws {
        let (store, directory) = try fake("failure")
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.refresh(); try await settled(store)
        let prior = store.state.snapshot
        store.refresh(manual: true); try await settled(store)
        #expect(store.state.snapshot == prior)
        #expect(store.status == .failed)
        store.suspend(); store.resume(); try await settled(store)
        #expect(store.status == .ready)
        #expect(store.state.snapshot!.fetchedAt > prior!.fetchedAt)
    }
    @Test func accountChangeClearsBeforeNewQuotaArrives() async throws {
        let (store, directory) = try fake("switch")
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.refresh(); try await settled(store)
        let priorKey = store.state.snapshot!.accountKey
        store.refresh(manual: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.client.quotaReadCount < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.state.snapshot == nil)
        try await settled(store)
        #expect(store.state.snapshot?.accountKey != priorKey)
    }
    @Test func consumptionRequiresConfirmedDeltaAndNotFirstLoad() async throws {
        let (store, directory) = try fake("consume")
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.refresh(); try await settled(store)
        #expect(store.consumptionSerial == 0)
        store.refresh(); try await settled(store)
        #expect(store.consumptionSerial == 1)
        store.suspend()
        #expect(store.consumptionSerial == 1)
    }
    @Test func initializationAccountNotificationDoesNotRestartRead() async throws {
        let (store, directory) = try fake("startup-notify")
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.refresh(); try await settled(store)
        #expect(store.status == .ready && store.state.snapshot?.selectedWindow?.remainingPercent == 70)
        #expect(store.client.quotaReadCount == 1 && store.client.requestCount == 4)
    }
    @Test func accountNotificationDuringReadClearsOldSnapshotAndRejectsMixedIdentity() async throws {
        let (store, directory) = try fake("notify-switch")
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.refresh(); try await settled(store)
        let oldKey = store.state.snapshot!.accountKey
        store.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.state.snapshot != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.state.snapshot == nil && store.refreshing)
        try await settled(store)
        #expect(store.state.snapshot == nil && store.state.error == .accountChanged)
        store.refresh(); try await settled(store)
        #expect(store.status == .ready && store.state.snapshot?.accountKey != oldKey)
        #expect(store.client.quotaReadCount == 3)
    }
    @Test(arguments: ["loading", "empty", "unknown", "long", "stale", "error", "logout", "low", "consuming", "working"])
    func demoNeverReadsService(_ scenario: String) {
        let client = QuotaClient(executable: URL(fileURLWithPath: "/synthetic/missing"))
        let store = QuotaStore(client: client, demo: true, demoScenario: scenario)
        defer { store.stop() }
        store.start(); store.refresh(manual: true)
        #expect(client.requestCount == 0 && client.processID == nil)
        if scenario == "loading" { #expect(store.status == .loading) }
        if scenario == "unknown" { #expect(store.state.snapshot?.selectedWindow == nil && store.state.snapshot?.availableResetCount == nil) }
        if scenario == "stale" { #expect(store.status == .stale) }
        if scenario == "long" { #expect(store.state.snapshot?.windows.count == 8) }
    }
}
