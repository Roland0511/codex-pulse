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
        #expect(connection.status == "未启用" && client.requestCount == 0 && client.processID == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
