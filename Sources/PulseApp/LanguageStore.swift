import Combine
import Foundation
import PulseCore

@MainActor final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    @Published private(set) var selection: PulseLanguage = .system
    @Published private(set) var text = PulseText()
    private var observer: NSObjectProtocol?
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    private var storage: UserDefaults { defaults ?? LocalDefaults.store }
    func start() {
        selection = storage.string(forKey: "language").flatMap(PulseLanguage.init(rawValue:)) ?? .system
        update()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                }
        }
    }
    func setSelection(_ language: PulseLanguage) {
        selection = language
        storage.set(language.rawValue, forKey: "language")
        update()
    }
    private func update() { text = PulseText(language: selection) }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

@MainActor func tr(_ key: String, _ arguments: CVarArg...) -> String {
    LanguageStore.shared.text.format(key, arguments: arguments)
}
