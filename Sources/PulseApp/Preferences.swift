import AppKit
import Carbon
import Combine
import PulseCore
import ServiceManagement
import SwiftUI

@MainActor enum LocalDefaults { static var store = UserDefaults.standard }

struct ShortcutChoice: Codable, Equatable {
    var key: String = "P"
    var command = true
    var option = true
    var control = true
    var shift = false
    var modifiers: UInt32 {
        (command ? UInt32(cmdKey) : 0) | (option ? UInt32(optionKey) : 0) |
        (control ? UInt32(controlKey) : 0) | (shift ? UInt32(shiftKey) : 0)
    }
    var label: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key }
    static let keyCodes: [String: UInt32] = ["P": 35, "U": 32, "K": 40, "J": 38, "Y": 16, "G": 5, "B": 11]
}

@MainActor final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var escapeReference: EventHotKeyRef?
    var action: (() -> Void)?
    var escapeAction: (() -> Void)?
    private(set) var choice = ShortcutChoice()
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let isEscape = id.id == 2
            Task { @MainActor in if isEscape { manager.escapeAction?() } else { manager.action?() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ next: ShortcutChoice) -> String? {
        guard let code = ShortcutChoice.keyCodes[next.key], [next.command, next.option, next.control, next.shift].filter({ $0 }).count >= 2 else {
            return "请选择至少两个修饰键"
        }
        let old = choice
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        let id = EventHotKeyID(signature: 0x50554c53, id: 1)
        let status = RegisterEventHotKey(code, next.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            if let oldCode = ShortcutChoice.keyCodes[old.key] {
                _ = RegisterEventHotKey(oldCode, old.modifiers, id, GetApplicationEventTarget(), 0, &reference)
            }
            return "快捷键被占用或系统拒绝注册（\(status)），请选择另一组"
        }
        choice = next
        if let data = try? JSONEncoder().encode(next) { LocalDefaults.store.set(data, forKey: "shortcut") }
        return nil
    }
    func watchEscape(_ enabled: Bool) -> String? {
        if let escapeReference { UnregisterEventHotKey(escapeReference) }; escapeReference = nil
        guard enabled else { return nil }
        let id = EventHotKeyID(signature: 0x50554c53, id: 2)
        let status = RegisterEventHotKey(53, 0, id, GetApplicationEventTarget(), 0, &escapeReference)
        return status == noErr ? nil : "Escape 全局收起不可用；可再次点击胶囊收起（\(status)）"
    }
    func stop() {
        if let escapeReference { UnregisterEventHotKey(escapeReference) }
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil; escapeReference = nil
    }
}

@MainActor final class Preferences: ObservableObject {
    @Published var shortcut = ShortcutChoice()
    @Published var message: String?
    @Published var launchEnabled = false
    @Published var appearance = "codex"
    @Published var executablePath = ""
    private var window: NSWindow?
    let hotkey: GlobalShortcut
    let store: QuotaStore
    let overlay: OverlayController
    let activityConnection: ActivityConnection
    init(hotkey: GlobalShortcut, store: QuotaStore, overlay: OverlayController) {
        self.hotkey = hotkey; self.store = store; self.overlay = overlay
        activityConnection = ActivityConnection(store: store)
        shortcut = LocalDefaults.store.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(ShortcutChoice.self, from: $0) } ?? ShortcutChoice()
        appearance = LocalDefaults.store.string(forKey: "appearance") ?? "codex"
        if !LocalDefaults.store.bool(forKey: "codexAppearanceMigration") {
            appearance = "codex"; LocalDefaults.store.set(true, forKey: "codexAppearanceMigration")
        }
        AppearanceStore.shared.start(appearance)
        executablePath = LocalDefaults.store.string(forKey: "codexExecutable") ?? ""
        launchEnabled = SMAppService.mainApp.status == .enabled
        if !store.demo { message = hotkey.register(shortcut) }
        applyAppearance()
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Codex Pulse 设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView(preferences: self, store: store, activityConnection: activityConnection))
            window.center(); self.window = window
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        activityConnection.refresh()
    }
    func saveShortcut() { if !store.demo { message = hotkey.register(shortcut) } }
    func setLaunch(_ enabled: Bool) {
        guard !store.demo else { message = "演示模式不注册开机启动"; return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchEnabled = SMAppService.mainApp.status == .enabled
            message = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置「登录项」中允许 Codex Pulse" : nil
        } catch { launchEnabled = SMAppService.mainApp.status == .enabled; message = "开机启动未更改：\(error.localizedDescription)" }
    }
    func applyAppearance() {
        LocalDefaults.store.set(appearance, forKey: "appearance")
        AppearanceStore.shared.setSelection(appearance)
    }
    func chooseExecutable() {
        let picker = NSOpenPanel()
        picker.title = "选择 Codex 可执行文件"; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
        executablePath = url.path; LocalDefaults.store.set(url.path, forKey: "codexExecutable")
        store.suspend(); store.client.executable = QuotaClient.nativeExecutable(url); store.resume()
    }
}

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: QuotaStore
    @ObservedObject var activityConnection: ActivityConnection
    @ObservedObject private var appearance = AppearanceStore.shared
    var body: some View {
        Form {
            Picker("外观", selection: $preferences.appearance) {
                Text("跟随 Codex").tag("codex"); Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
            }.onChange(of: preferences.appearance) { _, _ in preferences.applyAppearance() }
            if preferences.appearance == "codex", appearance.codex == nil {
                Text("Codex 外观配置暂不可用，当前跟随系统配色。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("开机启动", isOn: Binding(get: { preferences.launchEnabled }, set: preferences.setLaunch))
            Toggle("低额度提醒（20% / 10%）", isOn: Binding(get: { store.remindersEnabled }, set: store.enableReminders))
            if !store.demo {
                Toggle("工作特效", isOn: Binding(get: { activityConnection.installed }, set: activityConnection.setEnabled))
                    .disabled(activityConnection.checking)
                HStack {
                    Text(activityConnection.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if activityConnection.installed {
                        Button("信任步骤") { activityConnection.showTrustSteps() }
                        Button(activityConnection.checking ? "检查中…" : "检查连接") { activityConnection.refresh() }
                            .disabled(activityConnection.checking)
                    }
                }
            }
            HStack {
                Text("快捷键").help("显示或隐藏胶囊")
                Toggle("⌃", isOn: $preferences.shortcut.control).accessibilityLabel("Control 修饰键")
                Toggle("⌥", isOn: $preferences.shortcut.option).accessibilityLabel("Option 修饰键")
                Toggle("⇧", isOn: $preferences.shortcut.shift).accessibilityLabel("Shift 修饰键")
                Toggle("⌘", isOn: $preferences.shortcut.command).accessibilityLabel("Command 修饰键")
                Picker("按键", selection: $preferences.shortcut.key) {
                    ForEach(ShortcutChoice.keyCodes.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 58)
            }
            Button("应用快捷键") { preferences.saveShortcut() }
            HStack {
                Text("Codex 路径").foregroundStyle(.secondary)
                Spacer(); Button("选择…") { preferences.chooseExecutable() }
            }
            if !preferences.executablePath.isEmpty { Text(preferences.executablePath).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let message = preferences.message ?? store.reminderMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("额度快照只保存在内存中。提醒去重记录保存在本机。通知仅在主动启用时申请权限。")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).frame(width: 400).padding(8)
    }
}
