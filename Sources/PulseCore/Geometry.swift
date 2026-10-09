import Foundation
import CoreGraphics

public enum DockSide: String, Codable, Sendable { case left, right }

public struct OverlayPosition: Codable, Equatable, Sendable {
    public var screenID: String
    public var x: Double
    public var y: Double
    public var side: DockSide?
    public init(screenID: String, x: Double, y: Double, side: DockSide?) {
        self.screenID = screenID; self.x = min(1, max(0, x)); self.y = min(1, max(0, y)); self.side = side
    }
    public func frame(in visible: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        var originX = visible.minX + max(0, visible.width - width) * x
        if side == .left { originX = visible.minX }
        if side == .right { originX = visible.maxX - width }
        return CGRect(x: originX, y: visible.minY + max(0, visible.height - height) * y, width: width, height: height)
    }
    public static func capture(frame: CGRect, visible: CGRect, screenID: String, side: DockSide?) -> Self {
        Self(screenID: screenID, x: (frame.minX - visible.minX) / max(1, visible.width - frame.width),
             y: (frame.minY - visible.minY) / max(1, visible.height - frame.height), side: side)
    }
}

public struct Attachment: Equatable, Sendable {
    public let side: DockSide?
    public let progress: Double
    public static func calculate(intended: CGRect, visible: CGRect, travel: Double = 32) -> Self {
        let left = intended.minX - visible.minX, right = visible.maxX - intended.maxX
        let gap = min(left, right)
        guard gap <= travel else { return Self(side: nil, progress: 0) }
        let p = min(1, max(0, 1 - gap / travel))
        return Self(side: left < right ? .left : .right, progress: p * p * (3 - 2 * p))
    }
}
