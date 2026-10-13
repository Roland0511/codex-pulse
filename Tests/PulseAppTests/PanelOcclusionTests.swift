import AppKit
import QuartzCore
import Testing
@testable import PulseApp

@Suite("遮挡区域") struct PanelOcclusionTests {
    @Test func overlappingCoversRemainHiddenWithoutXorHoles() {
        let region = PanelVisibleRegion(frame: CGRect(x: 10, y: 20, width: 100, height: 60), covers: [
            CGRect(x: 40, y: 0, width: 30, height: 100), CGRect(x: 60, y: 0, width: 30, height: 100)])
        #expect(region.rectangles.reduce(0) { $0 + $1.width * $1.height } == 3000)
        #expect(region.contains(CGPoint(x: 20, y: 30)))
        #expect(!region.contains(CGPoint(x: 65, y: 30)))
        #expect(!region.rectangles.contains { $0.contains(CGPoint(x: 65, y: 30)) })
        #expect(region.contains(CGPoint(x: 105, y: 30)))
    }
    @Test func fullCoverAndNonintersection() {
        let frame = CGRect(x: -400, y: 20, width: 86, height: 68)
        #expect(PanelVisibleRegion(frame: frame, covers: [frame]).rectangles.isEmpty)
        #expect(PanelVisibleRegion(frame: frame, covers: [frame.offsetBy(dx: 100, dy: 0)]).rectangles == [frame])
    }
}

@MainActor private final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

@Suite("翻转视图遮挡坐标") @MainActor struct PanelClipMaskTests {
    @Test func upperScreenCoverMapsToTopOfFlippedHostingView() throws {
        let view = FlippedClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let mask = PanelClipMask()
        mask.apply(PanelVisibleRegion(frame: CGRect(x: 300, y: 200, width: 100, height: 100),
            covers: [CGRect(x: 300, y: 250, width: 100, height: 50)]), to: view)
        let shape = try #require(view.layer?.mask as? CAShapeLayer)
        #expect(shape.path?.contains(CGPoint(x: 50, y: 10)) == false)
        #expect(shape.path?.contains(CGPoint(x: 50, y: 90)) == true)
    }
}
