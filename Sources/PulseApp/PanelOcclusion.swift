import AppKit
import QuartzCore

/// Subtract a union of covering rectangles; overlapping covers must never reopen a hole.
struct PanelVisibleRegion {
    let frame: CGRect
    let covers: [CGRect]
    var rectangles: [CGRect] {
        covers.reduce([frame]) { regions, cover in
            regions.flatMap { region -> [CGRect] in
                let cut = region.intersection(cover)
                guard !cut.isNull, !cut.isEmpty else { return [region] }
                return [
                    CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                    CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
                    CGRect(x: region.minX, y: cut.minY, width: cut.minX - region.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: region.maxX - cut.maxX, height: cut.height)
                ].filter { !$0.isEmpty }
            }
        }
    }
    func contains(_ point: CGPoint) -> Bool { frame.contains(point) && !covers.contains { $0.contains(point) } }
}

/// Mask a stable outer view layer without publishing SwiftUI model changes.
@MainActor final class PanelClipMask {
    private let clipping = CAShapeLayer()
    private var lastRegion: PanelVisibleRegion?
    private weak var lastView: NSView?
    func apply(_ region: PanelVisibleRegion, to view: NSView) {
        guard lastView !== view || lastRegion?.frame != region.frame || lastRegion?.covers != region.covers else { return }
        lastView = view; lastRegion = region
        if !view.wantsLayer { view.wantsLayer = true }
        if region.covers.isEmpty, view.layer?.mask == nil { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if region.covers.isEmpty { view.layer?.mask = nil }
        else {
            let path = CGMutablePath()
            for rect in region.rectangles {
                var local = rect.offsetBy(dx: -region.frame.minX, dy: -region.frame.minY)
                if view.isFlipped { local.origin.y = region.frame.height - local.maxY }
                path.addRect(local)
            }
            clipping.frame = view.bounds; clipping.path = path
            view.layer?.mask = clipping
        }
        CATransaction.commit()
    }
}

/// Keep the mask outside NSHostingView: SwiftUI manages/replaces its backing layers.
@MainActor final class PanelMaskContainer: NSView {
    let hosting: NSView
    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: hosting.frame)
        wantsLayer = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }
    override func layout() {
        super.layout()
        if hosting.frame != bounds { hosting.frame = bounds }
    }
    required init?(coder: NSCoder) { nil }
}
