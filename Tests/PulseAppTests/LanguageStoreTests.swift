import Foundation
import Testing
import PulseCore
@testable import PulseApp

@Suite("Language preferences") @MainActor struct LanguageStoreTests {
    @Test func selectionPersistsWithoutChangingOtherPreferences() {
        let name = "pulse-language-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: "appearance")
        defaults.set(false, forKey: "remindersEnabled")
        let store = LanguageStore(defaults: defaults)
        store.start(); defer { store.stop() }
        store.setSelection(.english)
        #expect(store.text.string("settings.title") == "Codex Pulse Settings")
        store.setSelection(.simplifiedChinese)
        #expect(store.text.string("settings.title") == "Codex Pulse 设置")
        let restored = LanguageStore(defaults: defaults)
        restored.start(); defer { restored.stop() }
        #expect(restored.selection == .simplifiedChinese)
        #expect(defaults.string(forKey: "appearance") == "dark")
        #expect(defaults.bool(forKey: "remindersEnabled") == false)
        restored.setSelection(.system)
        #expect(defaults.string(forKey: "language") == "system")
    }
}
