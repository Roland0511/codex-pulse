import AppKit
import Darwin
import Testing
@testable import PulseApp

@Suite("窗口跟随渲染与层级", .serialized) @MainActor struct WindowFollowingPerformanceTests {
    @Test func normalLevelTracksHostWithoutCoveringForegroundWindow() async throws {
        _ = NSApplication.shared
        let rect = CGRect(x: 150, y: 150, width: 400, height: 300)
        let host = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        let foreground = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: CGRect(x: 150, y: 180, width: 54, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for window in [host, foreground, panel] { window.isReleasedWhenClosed = false; window.level = .normal }
        defer { for window in [panel, foreground, host] { window.orderOut(nil); window.close() } }
        func waitForOrder(_ windows: [NSWindow]) async throws {
            var matched = false
            for _ in 0..<100 {
                let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let ids = rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
                let positions = windows.compactMap { ids.firstIndex(of: $0.windowNumber) }
                matched = positions.count == windows.count && zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
                if matched { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(matched, "Window Server did not reach the expected front-to-back order")
        }
        host.orderFrontRegardless(); foreground.orderFrontRegardless()
        try await waitForOrder([foreground, host])
        let source = SystemCodexWindowSource()
        let target = CodexWindow(id: UInt32(host.windowNumber), frame: host.frame, isOnScreen: true)
        source.orderPanel(panel, above: target, force: true)
        try await waitForOrder([foreground, panel, host])
        #expect(panel.isVisible)
        host.orderFrontRegardless()
        try await waitForOrder([host, foreground])
        source.orderPanel(panel, above: target, force: true)
        try await waitForOrder([panel, host, foreground])
        foreground.orderFrontRegardless()
        try await waitForOrder([foreground, host])
        source.orderPanel(panel, above: target, force: true)
        try await waitForOrder([foreground, panel, host])
        #expect(panel.isVisible) // Occlusion is not an application-focus hide operation.
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
            return true
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
        let report: [String: Any] = ["frames": count, "durationSeconds": elapsed, "effectiveFPS": Double(count) / elapsed,
            "displayMaxFPS": screen.maximumFramesPerSecond, "cpuSeconds": cpuUsed,
            "medianIntervalMs": intervals[intervals.count / 2],
            "p95IntervalMs": intervals[Int(Double(intervals.count - 1) * 0.95)],
            "p95ReadMs": sortedCosts[Int(Double(sortedCosts.count - 1) * 0.95)]]
        print("Native follow benchmark: \(report)")
        if let path = ProcessInfo.processInfo.environment["PULSE_NATIVE_FOLLOW_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
