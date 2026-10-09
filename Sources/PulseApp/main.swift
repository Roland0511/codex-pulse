import AppKit
import Combine
import PulseCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: QuotaStore!
    private var overlay: OverlayController!
    private var preferences: Preferences!
    private var statusItem: NSStatusItem!
    private var shortcut: GlobalShortcut!
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private let instanceLock = InstanceLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        do {
            guard try instanceLock.acquire(at: support.appendingPathComponent("CodexPulse/instance.lock")) else {
                // 现有实例负责显示；新进程在创建窗口、菜单栏或服务之前退出。
                DistributedNotificationCenter.default().postNotificationName(.init("dev.roland.codex-pulse.showExisting"), object: nil)
                NSApp.terminate(nil); return
            }
        } catch {
            fputs(tr("error.instance"), stderr)
            NSApp.terminate(nil); return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showExisting),
            name: .init("dev.roland.codex-pulse.showExisting"), object: nil)
        NSApp.setActivationPolicy(.accessory)
        let demo = CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "PulseDemoMode") as? Bool == true
        if demo { LocalDefaults.store = UserDefaults(suiteName: "dev.roland.codex-pulse.demo.preferences")! }
        LanguageStore.shared.start()
        let preferred = LocalDefaults.store.string(forKey: "codexExecutable")
        let client = QuotaClient(executable: QuotaClient.discoverExecutable(preferred: preferred), inspectHooks: true)
        let scenarioIndex = CommandLine.arguments.firstIndex(of: "--demo-scenario")
        let scenario = scenarioIndex.flatMap { index in index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil }
            ?? Bundle.main.object(forInfoDictionaryKey: "PulseDemoScenario") as? String ?? "normal"
        store = QuotaStore(client: client, demo: demo, demoScenario: scenario)
        store.restoreReminders(!demo && LocalDefaults.store.bool(forKey: "remindersEnabled"))
        overlay = OverlayController(store: store)
        shortcut = GlobalShortcut(); shortcut.action = { [weak self] in self?.overlay.toggleVisible() }
        shortcut.escapeAction = { [weak self] in self?.overlay.close() }
        preferences = Preferences(hotkey: shortcut, store: store, overlay: overlay)
        overlay.model.$expanded.sink { [weak self] expanded in
            guard !demo else { return }
            if let message = self?.shortcut.watchEscape(expanded) { self?.preferences.message = message }
        }.store(in: &subscriptions)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.lefthalf.filled", accessibilityDescription: tr("menu.accessibility"))
        LanguageStore.shared.$text.dropFirst().sink { [weak self] text in
            self?.statusItem.button?.image?.accessibilityDescription = text.string("menu.accessibility")
            self?.statusItem.button?.toolTip = text.string("menu.accessibility")
        }.store(in: &subscriptions)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        // 原生主菜单提供键盘等效动作，菜单栏胶囊入口复用同一组处理器。
        let root = NSMenu(), appMenu = NSMenu()
        appMenu.delegate = self; menuWillOpen(appMenu)
        let rootItem = NSMenuItem(title: "Codex Pulse", action: nil, keyEquivalent: "")
        rootItem.submenu = appMenu; root.addItem(rootItem); NSApp.mainMenu = root
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.resume() }
            })
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockChanged(_:)), name: NSNotification.Name(name), object: nil)
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.timeChanged() }
        })
        store.start(); overlay.show(); preferences.activityConnection.refresh()
    }
    @objc private func lockChanged(_ notification: Notification) {
        if notification.name.rawValue == "com.apple.screenIsLocked" { store.suspend() }
        else { store.resume() }
    }
    @objc private func showExisting() { overlay?.show() }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        item(menu, overlay.visible ? tr("menu.hide") : tr("menu.show"), #selector(toggle), "")
        item(menu, tr("menu.details"), #selector(openDetails), "")
        item(menu, store.refreshing ? tr("status.refreshing") : tr("menu.refresh"), #selector(refresh), "r").isEnabled = !store.refreshing && !store.demo
        menu.addItem(.separator())
        let position = NSMenu()
        item(position, tr("menu.center"), #selector(center), "")
        item(position, tr("menu.left"), #selector(left), "")
        item(position, tr("menu.right"), #selector(right), "")
        let positionItem = NSMenuItem(title: tr("menu.position"), action: nil, keyEquivalent: ""); positionItem.submenu = position; menu.addItem(positionItem)
        item(menu, tr("reminders.menu"), #selector(reminders), "").state = store.remindersEnabled ? .on : .off
        item(menu, tr("launch"), #selector(launchAtLogin), "").state = preferences.launchEnabled ? .on : .off
        if !store.demo, !preferences.activityConnection.verified {
            item(menu, preferences.activityConnection.installed ? tr("menu.activity", preferences.activityConnection.status) : tr("menu.enableActivity"), #selector(settings), "")
        }
        item(menu, tr("menu.settings", shortcut.choice.label), #selector(settings), ",")
        item(menu, tr("menu.openCodex"), #selector(openCodex), "")
        menu.addItem(.separator())
        item(menu, tr("menu.quit"), #selector(quit), "q")
    }
    @discardableResult private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item); return item
    }
    @objc private func toggle() { overlay.toggleVisible() }
    @objc private func openDetails() { overlay.show(keyboard: true) }
    @objc private func refresh() { store.refresh(manual: true) }
    @objc private func center() { overlay.place(nil) }
    @objc private func left() { overlay.place(.left) }
    @objc private func right() { overlay.place(.right) }
    @objc private func reminders() { store.enableReminders(!store.remindersEnabled) }
    @objc private func launchAtLogin() { preferences.setLaunch(!preferences.launchEnabled) }
    @objc private func settings() { preferences.show() }
    @objc private func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        preferences?.activityConnection.stop(); store?.stop(); overlay?.stop(); shortcut?.stop(); AppearanceStore.shared.stop(); instanceLock.release()
        LanguageStore.shared.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
