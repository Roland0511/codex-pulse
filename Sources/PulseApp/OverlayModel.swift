import AppKit
import Combine
import PulseCore

@MainActor final class OverlayModel: ObservableObject {
    @Published var width = DesignTokens.capsuleWidth
    @Published var height = DesignTokens.height
    @Published var side: DockSide?
    @Published var blend = 0.0
    @Published var expanded = false
    @Published var hovered = false
    @Published var pinned = false
    @Published var keyboardOpened = false
    @Published var flash = 0.0
    @Published var consumptionDetected = false
    @Published var working = false
    @Published var consumptionAnimating = false
    var consumptionMessage: String { working ? tr("status.working") : tr("status.consuming") }
    private let motionPreference: () -> Bool
    init(motionPreference: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.motionPreference = motionPreference
    }
    var reduceMotion: Bool { motionPreference() }
    var compactWidth: Double {
        guard side != nil else { return DesignTokens.capsuleWidth }
        return pinned || hovered ? DesignTokens.dockedExpandedWidth : DesignTokens.dockedWidth
    }
    var toggle: (() -> Void)?
    var close: (() -> Void)?
    var togglePin: (() -> Void)?
    var hover: ((Bool) -> Void)?
    var dragBegan: ((NSPoint) -> Void)?
    var dragMoved: ((NSPoint) -> Void)?
    var dragEnded: (() -> Void)?
}
