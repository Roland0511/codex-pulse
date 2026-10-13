import AppKit
import Darwin
import Combine
import QuartzCore
@testable import PulseCore
import Testing
@testable import PulseApp

/// Own test window only; no driving or reading contents of the user's Codex window.
@MainActor private final class NativeTestHost: CodexWindowSource {
    let window: NSWindow
    var reads: [Double] = []
    init(_ window: NSWindow) { self.window = window }
    var isCodexActive: Bool { true }
    func activate() {}
    func windows(matching id: CGWindowID?) -> [CodexWindow] {
        reads.append(ProcessInfo.processInfo.systemUptime)
        return [CodexWindow(id: UInt32(window.windowNumber), frame: window.frame, isOnScreen: true)]
    }
    func orderPanel(_ panel: PulsePanel, above host: CodexWindow, force: Bool) {
        if force || !panel.isVisible { panel.order(.above, relativeTo: window.windowNumber) }
    }
}

@Suite("窗口跟随渲染与层级", .serialized) @MainActor struct WindowFollowingPerformanceTests {
    @Test func stableLevelClipsForegroundWithoutRepeatedOrdering() async throws {
        _ = NSApplication.shared
        let rect = CGRect(x: 150, y: 150, width: 400, height: 300)
        let host = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        let foreground = NSWindow(contentRect: CGRect(x: 170, y: 180, width: 330, height: 230), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = PulsePanel(contentRect: CGRect(x: 150, y: 180, width: 54, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSView()
        for window in [host, foreground, panel] { window.isReleasedWhenClosed = false; window.level = .normal }
        panel.level = PulsePanel.attachedLevel
        defer { for window in [panel, foreground, host] { window.orderOut(nil); window.close() } }
        host.orderFrontRegardless(); foreground.orderFrontRegardless()
        let source = SystemCodexWindowSource(ownerPIDs: { [getpid()] })
        var sawCover = false
        for _ in 0..<100 {
            if let target = source.windows(matching: UInt32(host.windowNumber)).first {
                source.orderPanel(panel, above: target, force: true)
                if panel.occludingFrames.contains(foreground.frame) { sawCover = true; break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawCover)
        #expect(panel.isVisible)
        let region = PanelVisibleRegion(frame: panel.frame, covers: panel.occludingFrames)
        #expect(region.contains(CGPoint(x: 155, y: 190)))
        #expect(!region.contains(CGPoint(x: 190, y: 190)))
        let mask = try #require(panel.contentView?.layer?.mask as? CAShapeLayer)
        #expect(mask.path?.contains(CGPoint(x: 5, y: 10)) == true)
        #expect(mask.path?.contains(CGPoint(x: 40, y: 10)) == false)
        panel.refreshPointerPassthrough(at: CGPoint(x: 190, y: 190))
        #expect(panel.ignoresMouseEvents)
        panel.refreshPointerPassthrough(at: CGPoint(x: 155, y: 190))
        #expect(!panel.ignoresMouseEvents)
        // Keep activating the host's native window group; the overlay cannot be pushed below it.
        for _ in 0..<15 {
            host.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(20))
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let ids = rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
            #expect(try #require(ids.firstIndex(of: panel.windowNumber)) < #require(ids.firstIndex(of: host.windowNumber)))
        }
        foreground.orderOut(nil)
        for _ in 0..<100 {
            let target = try #require(source.windows(matching: UInt32(host.windowNumber)).first)
            source.orderPanel(panel, above: target, force: true)
            if panel.occludingFrames.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.occludingFrames.isEmpty)
        #expect(panel.contentView?.layer?.mask == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_NATIVE_FOLLOW_BENCHMARK"] == "1"))
    func nativeDisplayClockMeasuresGeometryReadCostAndStops() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let source = SystemCodexWindowSource()
        let host = try #require(source.windows(matching: nil).first(where: { $0.isOnScreen }))
        let clock = WindowFollowClock()
        defer { clock.stop() }
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let cpuStart = cpuTime()
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [Double] = []
        var costs: [Double] = []
        clock.start(on: screen) {
            let start = ProcessInfo.processInfo.systemUptime
            _ = source.windows(matching: host.id)
            costs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            samples.append(start)
            return .changed
        }
        try await Task.sleep(for: .seconds(5))
        clock.stop()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let cpuUsed = cpuTime() - cpuStart
        let count = samples.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(samples.count == count)
        #expect(count >= 30)
        let intervals = zip(samples.dropFirst(), samples).map { ($0 - $1) * 1000 }.sorted()
        let sortedCosts = costs.sorted()
        var report: [String: Any] = ["frames": count, "durationSeconds": elapsed, "effectiveFPS": Double(count) / elapsed,
            "displayMaxFPS": screen.maximumFramesPerSecond, "cpuSeconds": cpuUsed,
            "medianIntervalMs": intervals[intervals.count / 2],
            "p95IntervalMs": intervals[Int(Double(intervals.count - 1) * 0.95)],
            "p95ReadMs": sortedCosts[Int(Double(sortedCosts.count - 1) * 0.95)]]
        var idleSamples = 0
        clock.start(on: screen) {
            _ = source.windows(matching: host.id)
            idleSamples += 1
            return .stationary
        }
        try await Task.sleep(for: .milliseconds(600))
        idleSamples = 0
        let idleCPUStart = cpuTime(), idleStart = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(5))
        let idleElapsed = ProcessInfo.processInfo.systemUptime - idleStart
        let idleCPU = cpuTime() - idleCPUStart
        clock.stop()
        let idleRate = Double(idleSamples) / idleElapsed
        #expect(idleRate < 35 && idleRate > 20)
        #expect(idleRate < Double(count) / elapsed * 0.65)
        report["idleSamples"] = idleSamples; report["idleDurationSeconds"] = idleElapsed
        report["idleHz"] = idleRate; report["idleCPUSeconds"] = idleCPU
        print("Native follow benchmark: \(report)")
        if let path = ProcessInfo.processInfo.environment["PULSE_NATIVE_FOLLOW_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_NATIVE_FOLLOW_BENCHMARK"] == "1"))
    func adaptiveQueriesKeepRealExpansionAndMovingHostIndependent() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let original = LocalDefaults.store
        let suite = "dev.roland.codex-pulse.adaptive-tests.\(UUID().uuidString)"
        LocalDefaults.store = try #require(UserDefaults(suiteName: suite))
        defer { LocalDefaults.store.removePersistentDomain(forName: suite); LocalDefaults.store = original }
        let area = screen.visibleFrame
        let host = NSWindow(contentRect: CGRect(x: area.minX + 80, y: area.minY + 80, width: min(700, area.width - 200), height: min(500, area.height - 160)), styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.orderFrontRegardless()
        defer { host.orderOut(nil); host.close() }
        let source = NativeTestHost(host)
        let store = QuotaStore(client: QuotaClient(executable: nil), demo: true)
        let model = OverlayModel(motionPreference: { false })
        let overlay = OverlayController(store: store, model: model, windowSource: source)
        defer { overlay.stop(); store.stop() }
        overlay.placeInCodex(.right)
        try await Task.sleep(for: .milliseconds(650))
        source.reads.removeAll()
        var widthTimes: [Double] = [], widths: [Double] = []
        let observer = model.objectWillChange.sink {
            if widths.last != model.width {
                widths.append(model.width); widthTimes.append(ProcessInfo.processInfo.systemUptime)
            }
        }
        defer { observer.cancel() }
        // Genuine OverlayController expansion, while geometry reads are in idle mode.
        overlay.open()
        try await Task.sleep(for: .milliseconds(270))
        let idleExpansionFrames = widths.count, idleExpansionReads = source.reads.count
        let idleAnimationGaps = zip(widthTimes.dropFirst(), widthTimes).map { $0 - $1 }.sorted()
        #expect(idleExpansionFrames >= 8)
        #expect(idleExpansionReads <= 12)
        #expect(abs(model.width - DesignTokens.detailsWidth) < 0.001)
        overlay.close()
        try await Task.sleep(for: .milliseconds(270))
        widths.removeAll(); widthTimes.removeAll(); source.reads.removeAll()
        let movementStart = ProcessInfo.processInfo.systemUptime
        let origin = host.frame.origin
        host.setFrameOrigin(NSPoint(x: origin.x + 1, y: origin.y))
        overlay.open()
        var firstFollow: Double?
        for index in 1...70 {
            host.setFrameOrigin(NSPoint(x: origin.x + Double(index), y: origin.y + Double(index) / 2))
            try await Task.sleep(for: .milliseconds(16))
            if firstFollow == nil, overlay.attachedWindow?.frame.origin != origin {
                firstFollow = ProcessInfo.processInfo.systemUptime
            }
        }
        let movementEnd = ProcessInfo.processInfo.systemUptime
        let movementReads = source.reads.filter { $0 >= movementStart && $0 <= movementEnd }
        let followLatency = try #require(firstFollow) - movementStart
        #expect(followLatency < 0.09)
        #expect(Double(movementReads.count) / (movementEnd - movementStart) > 45)
        #expect(widths.count >= 8)
        #expect(abs(model.width - DesignTokens.detailsWidth) < 0.001)
        #expect(overlay.attachedWindow?.frame == host.frame)
        let gaps = zip(movementReads.dropFirst(), movementReads).map { $0 - $1 }.sorted()
        let animationGaps = zip(widthTimes.dropFirst(), widthTimes).map { $0 - $1 }.sorted()
        try await Task.sleep(for: .milliseconds(500))
        source.reads.removeAll()
        try await Task.sleep(for: .milliseconds(500))
        #expect(source.reads.count <= 20)
        let report: [String: Any] = ["idleExpansionFrames": idleExpansionFrames,
            "idleExpansionGeometryReads": idleExpansionReads, "movingExpansionFrames": widths.count,
            "idleExpansionMedianIntervalMs": idleAnimationGaps[idleAnimationGaps.count / 2] * 1000,
            "firstFollowLatencyMs": followLatency * 1000, "movingSamples": movementReads.count,
            "movingDurationSeconds": movementEnd - movementStart,
            "movingP95IntervalMs": gaps[Int(Double(gaps.count - 1) * 0.95)] * 1000,
            "expansionMedianIntervalMs": animationGaps[animationGaps.count / 2] * 1000,
            "settledSamplesInHalfSecond": source.reads.count]
        print("Adaptive integration benchmark: \(report)")
        if let path = ProcessInfo.processInfo.environment["PULSE_NATIVE_ADAPTIVE_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

}
