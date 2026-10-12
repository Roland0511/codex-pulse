import Testing
import Foundation
@testable import PulseCore

@Suite("Codex 窗口内侧几何") struct WindowDockTests {
    let window = CGRect(x: 100, y: 200, width: 800, height: 600)
    let screen = CGRect(x: 0, y: 0, width: 1400, height: 1000)

    @Test func onlyNearbyInnerEdgesAtTheSameHeightAttract() {
        let left = WindowDockPosition.attachment(intended: CGRect(x: 116, y: 400, width: 180, height: 36), window: window, travel: 32)
        let right = WindowDockPosition.attachment(intended: CGRect(x: 704, y: 400, width: 180, height: 36), window: window, travel: 32)
        #expect(left?.side == .left && right?.side == .right && left?.progress == right?.progress)
        #expect(left?.progress == 0.5)
        for origin in [CGPoint(x: 66, y: 400), CGPoint(x: 134, y: 400), CGPoint(x: 100, y: 850)] {
            #expect(WindowDockPosition.attachment(intended: CGRect(origin: origin, size: CGSize(width: 180, height: 36)), window: window, travel: 32) == nil)
        }
    }

    @Test func followsMovementResizeAndExpansionWithoutChangingAnchor() throws {
        let position = WindowDockPosition(side: .right, y: 0.25)
        let compact = try #require(position.frame(in: window, visible: screen, size: CGSize(width: 54, height: 36), compactHeight: 36))
        let expanded = try #require(position.frame(in: window, visible: screen, size: CGSize(width: 280, height: 164), compactHeight: 36))
        #expect(compact.maxX == 900 && expanded.maxX == 900)
        #expect(compact.maxY == expanded.maxY)
        let moved = window.offsetBy(dx: 100, dy: 80)
        let next = try #require(position.frame(in: moved, visible: screen, size: compact.size, compactHeight: 36))
        #expect(next == compact.offsetBy(dx: 100, dy: 80))
        #expect(WindowDockPosition.capture(side: .right, frame: compact, window: window, compactHeight: 36) == position)
        let resized = try #require(position.frame(in: CGRect(x: 100, y: 200, width: 700, height: 400), visible: screen, size: compact.size, compactHeight: 36))
        #expect(resized.maxX == 800 && resized.minY == 291)
    }

    @Test func offscreenEdgesHideInsteadOfJumpingToDisplayEdge() throws {
        let host = CGRect(x: -200, y: 100, width: 800, height: 600)
        #expect(WindowDockPosition(side: .left, y: 0).frame(in: host, visible: screen, size: CGSize(width: 54, height: 36), compactHeight: 36) == nil)
        #expect(WindowDockPosition(side: .right, y: 0).frame(in: host, visible: screen, size: CGSize(width: 54, height: 36), compactHeight: 36)?.maxX == 600)
        let leftDisplay = CGRect(x: -1400, y: 0, width: 1400, height: 1000)
        #expect(WindowDockPosition(side: .left, y: 0.5).frame(in: host, visible: leftDisplay, size: CGSize(width: 54, height: 36), compactHeight: 36)?.minX == -200)
    }

    @Test func quartzConversionSupportsDisplaysAboveAndLeft() {
        #expect(WindowDockPosition.appKitFrame(quartz: CGRect(x: -1400, y: -700, width: 1200, height: 600), primaryHeight: 1000) == CGRect(x: -1400, y: 1100, width: 1200, height: 600))
    }

    @Test func persistenceIsIndependentOfEphemeralWindowIDs() throws {
        let position = WindowDockPosition(side: .left, y: 0.75)
        let data = try JSONEncoder().encode(position)
        #expect(try JSONDecoder().decode(WindowDockPosition.self, from: data) == position)
        #expect(WindowDockPosition(side: .left, y: .nan).y == 0.15)
    }
}

@Suite("重叠吸附目标") struct DockingProposalTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    @Test func maximizedOrNearbyWindowRequiresChoiceOnBothSides() {
        for inset in [0.0, 20.0] {
            let window = screen.insetBy(dx: inset, dy: inset)
            for x in [0.0, 820.0] {
                let proposal = DockingProposal(intended: CGRect(x: x, y: 300, width: 180, height: 36), visible: screen, window: window, travel: 32)
                #expect(proposal.requiresChoice)
            }
        }
    }
    @Test func distinctTargetsRemainDirectAndOffscreenEdgeIsNotOffered() {
        let host = screen.insetBy(dx: 150, dy: 100)
        let windowOnly = DockingProposal(intended: CGRect(x: 150, y: 300, width: 180, height: 36), visible: screen, window: host, travel: 32)
        #expect(windowOnly.window?.side == .left && windowOnly.screen.side == nil && !windowOnly.requiresChoice)
        let screenOnly = DockingProposal(intended: CGRect(x: 0, y: 300, width: 180, height: 36), visible: screen, window: host, travel: 32)
        #expect(screenOnly.window == nil && screenOnly.screen.side == .left && !screenOnly.requiresChoice)
        let outside = DockingProposal(intended: CGRect(x: 0, y: 300, width: 180, height: 36), visible: screen, window: screen.offsetBy(dx: -20, dy: 0), travel: 32)
        #expect(outside.window == nil)
    }
}
