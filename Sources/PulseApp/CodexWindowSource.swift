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
}

/// Only public Window Server geometry is read. No titles, pixels or Accessibility permission.
@MainActor final class SystemCodexWindowSource: CodexWindowSource {
    private var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated }
    }
    var isCodexActive: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex" }
    func activate() { applications.first?.activate(options: []) }

    func windows(matching id: CGWindowID? = nil) -> [CodexWindow] {
        let owners = Set(applications.map(\.processIdentifier))
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
