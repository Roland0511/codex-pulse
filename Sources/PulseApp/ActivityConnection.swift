import AppKit
import Combine
import Foundation
import PulseCore

@MainActor final class ActivityConnection: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var checking = false
    @Published private var statusKey = "activity.disabled"
    @Published private var trustCounts = (trusted: 0, found: 0)
    var status: String { tr(statusKey, trustCounts.trusted, trustCounts.found) }
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
            if installed { statusKey = "activity.installed" }
        }
    }
    func refresh(automatic: Bool = false) {
        guard let store, !store.demo, !checking else { return }
        if automatic && Date().timeIntervalSince(lastCheck) < 30 { return }
        do { installed = try installer.isInstalled() }
        catch { statusKey = "activity.unsafe"; verified = false; store.activity.setVerified(false); return }
        guard installed else { statusKey = "activity.disabled"; verified = false; store.activity.setVerified(false); return }
        checking = true; lastCheck = Date()
        check = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { checking = false; check = nil }
            do {
                let summary = try await store.inspectHookTrust(commands: installer.commands)
                guard !Task.isCancelled else { return }
                verified = summary.fullyTrusted && store.activity.message == nil
                trustCounts = (summary.trusted, summary.found)
                if store.activity.message != nil { statusKey = "activity.listener.failed" }
                else if summary.fullyTrusted { statusKey = "activity.ready" }
                else if summary.found < ActivityEvent.allCases.count { statusKey = "activity.missing" }
                else if summary.enabled < summary.found { statusKey = "activity.partial" }
                else { statusKey = "activity.trust" }
                store.activity.setVerified(verified)
            } catch {
                guard !Task.isCancelled else { return }
                verified = false; statusKey = "activity.check.failed"; store.activity.setVerified(false)
            }
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard let store, !store.demo, !checking else { return }
        if enabled {
            let alert = NSAlert()
            alert.messageText = tr("activity.install.title")
            alert.informativeText = tr("activity.install.body", installer.hooksURL.path)
            alert.addButton(withTitle: tr("activity.install")); alert.addButton(withTitle: tr("cancel"))
            alert.accessoryView = reviewView()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            store.activity.setVerified(false); verified = false
            try installer.change(install: enabled)
            installed = enabled; statusKey = enabled ? "activity.installed" : "activity.disabled"
            if enabled { refresh(); showTrustSteps() }
        } catch {
            installed = (try? installer.isInstalled()) == true
            statusKey = "activity.change.failed"
        }
    }
    func showTrustSteps() {
        guard let store, !store.demo else { return }
        let command = store.client.executable.map { ActivityHookInstaller.shellQuote($0.path) } ?? "codex"
        let alert = NSAlert()
        alert.messageText = tr("activity.trust.title")
        alert.informativeText = tr("activity.trust.body", command)
        alert.addButton(withTitle: tr("close")); alert.addButton(withTitle: tr("activity.copy")); alert.addButton(withTitle: tr("activity.definitions"))
        let result = alert.runModal()
        if result == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        } else if result == .alertThirdButtonReturn {
            let review = NSAlert(); review.messageText = tr("activity.definitions.title")
            review.accessoryView = reviewView(); review.addButton(withTitle: tr("close")); review.runModal()
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
