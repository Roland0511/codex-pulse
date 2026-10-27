import Foundation
import Testing
import PulseCore
@testable import PulseApp

@Suite("首次启动不自动安装") @MainActor struct ActivityConnectionTests {
    @Test func disabledConnectionDoesNotCreateFilesOrStartService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ActivityHookInstaller(hooksURL: root.appendingPathComponent("codex/hooks.json"),
            support: root.appendingPathComponent("support"), source: root.appendingPathComponent("helper"), verify: { _ in })
        let client = QuotaClient(executable: root.appendingPathComponent("missing-codex"), inspectHooks: true)
        let store = QuotaStore(client: client)
        let connection = ActivityConnection(store: store, installer: installer)
        defer { connection.stop(); store.stop() }
        connection.refresh()
        #expect(!connection.installed && !connection.verified && !connection.checking)
        #expect(connection.status == tr("activity.disabled") && client.requestCount == 0 && client.processID == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func startupRefreshRepairsLegacyHookWithoutInstallingHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ActivityHookInstaller(hooksURL: root.appendingPathComponent("codex/hooks.json"),
            support: root.appendingPathComponent("support"), source: root.appendingPathComponent("helper"), verify: { _ in })
        try FileManager.default.createDirectory(at: installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old: [String: Any] = ["hooks": ["SessionEnd": [["hooks": [["type": "command",
            "command": ActivityHookInstaller.shellQuote(installer.helper.path) + " --event SessionEnd", "async": true, "timeout": 2]]]]]]
        try JSONSerialization.data(withJSONObject: old).write(to: installer.hooksURL)
        let client = QuotaClient(executable: root.appendingPathComponent("missing-codex"), inspectHooks: true)
        let store = QuotaStore(client: client)
        let connection = ActivityConnection(store: store, installer: installer)
        defer { connection.stop(); store.stop() }
        connection.refresh()
        #expect(try !installer.repairLegacySessionEnd())
        #expect(try FileManager.default.contentsOfDirectory(atPath: installer.support.appendingPathComponent("hook-backups").path).count == 1)
        #expect(!connection.installed && !connection.verified && client.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: installer.helper.path))
    }
}
