import CoreGraphics

/// Resolve geometry first; a UI choice is required whenever both targets qualify.
public struct DockingProposal: Equatable, Sendable {
    public let screen: Attachment
    public let window: Attachment?
    public var requiresChoice: Bool { screen.side != nil && window?.side != nil }

    public init(intended: CGRect, visible: CGRect, window: CGRect?, travel: Double, pointer: CGPoint? = nil) {
        screen = Attachment.calculate(intended: intended, visible: visible, travel: travel)
        let grabPoint = pointer ?? CGPoint(x: intended.midX, y: intended.midY)
        if let window, window.insetBy(dx: -travel, dy: 0).contains(grabPoint), let attachment = WindowDockPosition.attachment(intended: intended, window: window, travel: travel),
           (attachment.side == .left ? window.minX >= visible.minX : window.maxX <= visible.maxX) {
            self.window = attachment
        } else { self.window = nil }
    }
}
