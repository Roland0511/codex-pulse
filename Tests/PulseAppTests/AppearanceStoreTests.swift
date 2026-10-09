import Foundation
import Testing
@testable import PulseApp

@Suite("外观配置变化监听", .serialized) @MainActor struct AppearanceStoreTests {
    @Test func atomicReplacementAndUnrelatedEditsOnlyUpdateAppearance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.toml")
        let fixture = """
        [desktop]
        appearanceTheme = "light"
        [desktop.appearanceLightChromeTheme]
        surface = "#FAFAFA"
        ink = "#121212"
        accent = "#123456"
        """
        try fixture.write(to: file, atomically: true, encoding: .utf8)
        let store = AppearanceStore(url: file)
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.start("codex")
        #expect(store.codex?.light?.accent == 0x123456)
        try fixture.replacingOccurrences(of: "#123456", with: "#654321").write(to: file, atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.codex?.light?.accent != 0x654321 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.codex?.light?.accent == 0x654321)
        let before = store.codex
        try ("unrelated = \"no effect\"\n" + fixture.replacingOccurrences(of: "#123456", with: "#654321"))
            .write(to: file, atomically: true, encoding: .utf8)
        store.reload(force: true)
        #expect(store.codex == before)
        store.setSelection("system"); #expect(!store.followsCodex)
        store.setSelection("codex"); #expect(store.followsCodex)
    }
}
