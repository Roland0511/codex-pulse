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
    func orderPanel(_ panel: PulsePanel, above window: CodexWindow, force: Bool)
}

/// Only public Window Server geometry is read. No titles, pixels or Accessibility permission.
@MainActor final class SystemCodexWindowSource: CodexWindowSource {
    private let ownerPIDs: @MainActor () -> Set<pid_t>
    init(ownerPIDs: @escaping @MainActor () -> Set<pid_t> = {
        Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated }.map(\.processIdentifier))
    }) { self.ownerPIDs = ownerPIDs }
    private var knownOwners: Set<pid_t> = []
    private var observedRows: [[String: Any]] = []
    private var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated }
    }
    var isCodexActive: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex" }
    func activate() { applications.first?.activate(options: []) }

    /// A stable overlay level avoids fighting another process's window group.
    /// Normal-level windows in front of the host are clipped from our own surface.
    func orderPanel(_ panel: PulsePanel, above window: CodexWindow, force: Bool) {
        guard let host = observedRows.firstIndex(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.id
        }), let height = NSScreen.screens.first?.frame.height else { return }
        let covers = observedRows[..<host].compactMap { row -> CGRect? in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let frame = WindowDockPosition.appKitFrame(quartz: rect, primaryHeight: height)
            return frame.intersects(panel.frame) ? frame : nil
        }
        panel.setOccludingFrames(covers)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func windows(matching id: CGWindowID? = nil) -> [CodexWindow] {
        if id == nil || knownOwners.isEmpty { knownOwners = ownerPIDs() }
        let owners = knownOwners
        guard !owners.isEmpty, let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        observedRows = rows
        // A selected minimized/off-space host must remain identifiable for recovery.
        let candidates: [[String: Any]]
        if let id, !rows.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) {
            candidates = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        } else { candidates = rows }
        return candidates.compactMap { row in
            guard (id == nil || (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id),
                  (id != nil || (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true),
                  let owner = row[kCGWindowOwnerPID as String] as? NSNumber, owners.contains(owner.int32Value),
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
