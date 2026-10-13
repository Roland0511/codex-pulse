import AppKit
import PulseCore

struct CodexWindow: Equatable {
    let id: CGWindowID
    let frame: CGRect
    let isOnScreen: Bool
}

@MainActor protocol CodexWindowSource: AnyObject {
    var isCodexActive: Bool { get }
    func windows(matching id: CGWindowID?) -> [CodexWindow]
    func activate()
    func orderPanel(_ panel: NSPanel, above window: CodexWindow, force: Bool)
}

/// Only public Window Server geometry is read. No titles, pixels or Accessibility permission.
@MainActor final class SystemCodexWindowSource: CodexWindowSource {
    private var knownOwners: Set<pid_t> = []
    private var lastStackingCheck = -Double.infinity
    private var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated }
    }
    var isCodexActive: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex" }
    func activate() { applications.first?.activate(options: []) }

    /// Match the host's normal window level. A foreground Finder window stays above both.
    func orderPanel(_ panel: NSPanel, above window: CodexWindow, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastStackingCheck >= 0.1 else { return }
        lastStackingCheck = now
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let order = rows.compactMap { row -> UInt32? in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        guard let host = order.firstIndex(of: window.id) else { return }
        if !force, let overlay = order.firstIndex(of: UInt32(panel.windowNumber)), overlay + 1 == host { return }
        panel.order(.above, relativeTo: Int(window.id))
    }

    func windows(matching id: CGWindowID? = nil) -> [CodexWindow] {
        if id == nil || knownOwners.isEmpty { knownOwners = Set(applications.map(\.processIdentifier)) }
        let owners = knownOwners
        guard !owners.isEmpty, let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let options: CGWindowListOption = id == nil ? [.optionOnScreenOnly, .excludeDesktopElements] : .optionIncludingWindow
        guard let rows = CGWindowListCopyWindowInfo(options, id ?? kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber, owners.contains(owner.int32Value),
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = row[kCGWindowNumber as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  // Exclude menu helpers, tooltips and tiny transient surfaces without reading their names.
                  rect.width >= DesignTokens.detailsWidth, rect.height >= DesignTokens.detailsSingleWindowHeight,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { return nil }
            return CodexWindow(id: number.uint32Value,
                               frame: WindowDockPosition.appKitFrame(quartz: rect, primaryHeight: primaryHeight),
                               isOnScreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
    }
}
