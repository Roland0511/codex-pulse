import AppKit
import Combine
import Foundation
import PulseCore

@MainActor final class ActivityConnection: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var checking = false
    @Published private(set) var status = "未启用"
    @Published private(set) var verified = false
    private weak var store: QuotaStore?
    let installer: ActivityHookInstaller
    private var check: Task<Void, Never>?
    private var lastCheck = Date.distantPast
    init(store: QuotaStore, installer: ActivityHookInstaller? = nil) {
        self.store = store
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let source = (Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL).appendingPathComponent("PulseActivityHook")
        self.installer = installer ?? ActivityHookInstaller(hooksURL: home.appendingPathComponent("hooks.json"),
            support: ActivitySocket.location.deletingLastPathComponent(), source: source)
        if !store.demo {
            store.activity.onUnverifiedSignal = { [weak self] in self?.refresh(automatic: true) }
            installed = (try? self.installer.isInstalled()) == true
            if installed { status = "已安装，等待审阅信任" }
        }
    }
    func refresh(automatic: Bool = false) {
        guard let store, !store.demo, !checking else { return }
        if automatic && Date().timeIntervalSince(lastCheck) < 30 { return }
        do { installed = try installer.isInstalled() }
        catch { status = "配置无法安全读取"; verified = false; store.activity.setVerified(false); return }
        guard installed else { status = "未启用"; verified = false; store.activity.setVerified(false); return }
        checking = true; lastCheck = Date()
        check = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { checking = false; check = nil }
            do {
                let summary = try await store.inspectHookTrust(commands: installer.commands)
                guard !Task.isCancelled else { return }
                verified = summary.fullyTrusted && store.activity.message == nil
                if let message = store.activity.message { status = message }
                else if summary.fullyTrusted { status = "已启用，连接就绪" }
                else if summary.found < ActivityEvent.allCases.count { status = "部分钩子未加载，请检查 Codex 配置" }
                else if summary.enabled < summary.found { status = "部分钩子未启用" }
                else { status = "等待审阅信任（\(summary.trusted)/\(summary.found)）" }
                store.activity.setVerified(verified)
            } catch {
                guard !Task.isCancelled else { return }
                verified = false; status = "暂时无法核对连接，请重试"; store.activity.setVerified(false)
            }
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard let store, !store.demo, !checking else { return }
        if enabled {
            let alert = NSAlert()
            alert.messageText = "启用工作特效"
            alert.informativeText = "将向 \(installer.hooksURL.path) 添加以下 12 条只读状态钩子，仅向本机发送哈希工作状态。保留其它钩子并备份；不读取聊天记录，也不输出或控制会话内容。通常后台执行；会话结束事件由 Codex 同步执行，最多 2 秒。安装后需要在 Codex 审阅信任。"
            alert.addButton(withTitle: "安装并启用"); alert.addButton(withTitle: "取消")
            alert.accessoryView = reviewView()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            store.activity.setVerified(false); verified = false
            try installer.change(install: enabled)
            installed = enabled; status = enabled ? "已安装，等待审阅信任" : "未启用"
            if enabled { refresh(); showTrustSteps() }
        } catch {
            installed = (try? installer.isInstalled()) == true
            status = "更改未完成，请检查文件权限或现有钩子格式"
        }
    }
    func showTrustSteps() {
        guard let store, !store.demo else { return }
        let command = store.client.executable.map { ActivityHookInstaller.shellQuote($0.path) } ?? "codex"
        let alert = NSAlert()
        alert.messageText = "在 Codex 审阅信任"
        alert.informativeText = "1. 在终端运行：\n\(command)\n\n2. 进入 Codex CLI 后输入 /hooks，审阅并信任 Pulse 的全部 12 条定义。\n\n3. 回到这里点击「检查连接」。信任前不会播放工作流光。"
        alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "复制启动命令"); alert.addButton(withTitle: "查看钩子定义")
        let result = alert.runModal()
        if result == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        } else if result == .alertThirdButtonReturn {
            let review = NSAlert(); review.messageText = "Codex Pulse 钩子定义"
            review.accessoryView = reviewView(); review.addButton(withTitle: "关闭"); review.runModal()
        }
    }
    private func reviewView() -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
        text.string = installer.reviewText; text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = text
        return scroll
    }
    func stop() { check?.cancel(); check = nil; store?.activity.onUnverifiedSignal = nil }
}
