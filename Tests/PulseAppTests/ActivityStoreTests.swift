import Darwin
import Foundation
import PulseCore
import Testing
@testable import PulseApp

@Suite("本机状态传输") @MainActor struct ActivityStoreTests {
    @Test func socketReceivesOnlyValidLiveMetadataAndStopsOnClose() async throws {
        let directory = URL(fileURLWithPath: "/tmp/pulse-" + UUID().uuidString.prefix(8))
        let url = directory.appendingPathComponent("activity.sock")
        let store = ActivityStore(url: url)
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.start(); store.setVerified(true); #expect(store.message == nil)
        let owner = ActivityOwner.read(getpid())!
        func signal(_ event: ActivityEvent, session: String = "synthetic") -> ActivitySignal {
            .init(event: event, session: ActivitySignal.hash(session), turn: ActivitySignal.hash("turn"), time: Date().timeIntervalSince1970, owner: owner)
        }
        try ActivitySocket.send(signal(.start), to: url)
        for _ in 0..<100 where !store.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.isWorking && store.hasReceivedEvent)
        #expect(store.lastReceivedEvent == .start)
        store.suspend(); #expect(!store.isWorking)
        store.resume(); #expect(store.isWorking)
        try ActivitySocket.send(signal(.stop), to: url)
        for _ in 0..<100 where store.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.isWorking)
        #expect(store.lastReceivedEvent == .stop)
        store.stop(); #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.lastReceivedEvent == nil)
        #expect(throws: (any Error).self) { try ActivitySocket.send(signal(.start), to: url) }
    }
    @Test func unsafeDirectoriesAndForeignOrExpiredSignalsAreRejected() throws {
        let directory = URL(fileURLWithPath: "/tmp/pulse-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o755)
        let store = ActivityStore(url: directory.appendingPathComponent("activity.sock"), alive: { _ in false })
        defer { store.stop() }
        store.start(); #expect(store.message != nil)
        store.receive(.init(event: .start, session: ActivitySignal.hash("one"), turn: ActivitySignal.hash("turn"),
                            time: Date().timeIntervalSince1970, owner: ActivityOwner.read(getpid())!))
        #expect(!store.isWorking && !store.hasReceivedEvent)
        #expect(store.lastReceivedEvent == nil)
    }
    @Test func signalWaitsForFullTrustAndLosingTrustStopsAnimation() {
        let store = ActivityStore()
        defer { store.stop() }
        var checks = 0; store.onUnverifiedSignal = { checks += 1 }
        let owner = ActivityOwner.read(getpid())!
        let signal = ActivitySignal(event: .start, session: ActivitySignal.hash("synthetic"), turn: ActivitySignal.hash("turn"),
                                    time: Date().timeIntervalSince1970, owner: owner)
        store.receive(signal)
        #expect(store.hasReceivedEvent && !store.isWorking && checks == 1)
        store.setVerified(true); #expect(store.isWorking)
        store.setVerified(false); #expect(!store.isWorking)
        store.setVerified(true); #expect(!store.isWorking)
    }
}
