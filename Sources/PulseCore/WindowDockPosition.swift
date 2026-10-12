import Foundation
import CoreGraphics

/// Persistent placement within a host window; window IDs are deliberately session-only.
public struct WindowDockPosition: Codable, Equatable, Sendable {
    public var side: DockSide
    public var y: Double

    public init(side: DockSide, y: Double) {
        self.side = side
        self.y = y.isFinite ? min(1, max(0, y)) : 0.15
    }

    public static func capture(side: DockSide, frame: CGRect, window: CGRect, compactHeight: Double) -> Self {
        Self(side: side, y: (frame.maxY - compactHeight - window.minY) / max(1, window.height - compactHeight))
    }

    /// Grow upward from the compact capsule's top, then keep the card within the visible host.
    public func frame(in window: CGRect, visible: CGRect, size: CGSize, compactHeight: Double) -> CGRect? {
        let region = window.intersection(visible)
        guard !region.isNull, region.width >= size.width, region.height >= compactHeight else { return nil }
        let x = side == .left ? window.minX : window.maxX - size.width
        // Never relocate an offscreen host edge to a different edge of the display.
        guard x >= visible.minX, x + size.width <= visible.maxX else { return nil }
        let height = min(size.height, region.height)
        let top = window.minY + max(0, window.height - compactHeight) * y + compactHeight
        return CGRect(x: x, y: min(region.maxY - height, max(region.minY, top - height)), width: size.width, height: height)
    }

    public static func attachment(intended: CGRect, window: CGRect, travel: Double) -> Attachment? {
        guard intended.midY >= window.minY, intended.midY <= window.maxY,
              window.width >= intended.width, window.height >= intended.height else { return nil }
        let left = abs(intended.minX - window.minX), right = abs(window.maxX - intended.maxX)
        let gap = min(left, right)
        guard gap <= travel else { return nil }
        let p = min(1, max(0, 1 - gap / travel))
        return Attachment(side: left <= right ? .left : .right, progress: p * p * (3 - 2 * p))
    }

    /// Quartz uses a top-left origin; AppKit uses the primary display's bottom-left origin.
    public static func appKitFrame(quartz: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }
}
