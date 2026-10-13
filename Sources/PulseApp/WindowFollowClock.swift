import AppKit
import QuartzCore

/// Scheduling policy for geometry queries only. It never controls UI animation clocks.
struct WindowFollowCadence {
    enum Sample { case changed, stationary, unavailable }
    enum Mode { case tracking, idle, unavailable }
    static let idleInterval = 1.0 / 30
    static let retryInterval = 0.25
    static let settlingTime = 0.35
    private var trackingUntil = -Double.infinity
    private(set) var mode = Mode.idle

    mutating func wake(at time: Double) {
        trackingUntil = time + Self.settlingTime
        mode = .tracking
    }

    mutating func observe(_ sample: Sample, at time: Double) {
        switch sample {
        case .changed: wake(at: time)
        case .stationary: mode = time < trackingUntil ? .tracking : .idle
        case .unavailable: trackingUntil = -Double.infinity; mode = .unavailable
        }
    }
}

/// This private display link schedules host geometry reads, not SwiftUI/resize animations.
/// Idle hosts use a 30 Hz timer; motion resumes display-rate queries with a settling grace.
@MainActor final class WindowFollowClock {
    @MainActor private final class Target: NSObject {
        weak var owner: WindowFollowClock?
        @objc func step(_ sender: AnyObject) {
            guard let owner else {
                (sender as? CADisplayLink)?.invalidate()
                (sender as? Timer)?.invalidate()
                return
            }
            owner.step()
        }
    }
    private let target = Target()
    private var link: CADisplayLink?
    private var retry: Timer?
    private var timerInterval: TimeInterval?
    private var screenNumber: NSNumber?
    private var tick: (() -> WindowFollowCadence.Sample)?
    private var cadence = WindowFollowCadence()
    private(set) var running = false

    init() { target.owner = self }

    func start(on screen: NSScreen?, tick: @escaping () -> WindowFollowCadence.Sample) {
        stop()
        self.tick = tick; running = true
        cadence.wake(at: ProcessInfo.processInfo.systemUptime)
        useScreen(screen)
        step()
    }

    func useScreen(_ screen: NSScreen?) {
        guard running, let screen else { return }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard link == nil || number != screenNumber else { return }
        link?.invalidate(); screenNumber = number
        let next = screen.displayLink(target: target, selector: #selector(Target.step))
        let rate = Float(max(60, screen.maximumFramesPerSecond))
        next.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        next.isPaused = cadence.mode != .tracking
        next.add(to: .main, forMode: .common)
        link = next
    }

    private func step() {
        guard running else { return }
        let sample = tick?() ?? .unavailable
        guard running else { return }
        cadence.observe(sample, at: ProcessInfo.processInfo.systemUptime)
        schedule()
    }

    private func schedule() {
        link?.isPaused = cadence.mode != .tracking
        let interval: TimeInterval?
        switch cadence.mode {
        case .tracking: interval = link == nil ? WindowFollowCadence.idleInterval : nil
        case .idle: interval = WindowFollowCadence.idleInterval
        case .unavailable: interval = WindowFollowCadence.retryInterval
        }
        guard interval != timerInterval else { return }
        retry?.invalidate(); retry = nil; timerInterval = interval
        if let interval {
            let timer = Timer(timeInterval: interval, target: target, selector: #selector(Target.step), userInfo: nil, repeats: true)
            // Bound coalescing while idle so the first movement is picked up promptly.
            timer.tolerance = interval * 0.05
            RunLoop.main.add(timer, forMode: .common); retry = timer
        }
    }

    func refresh() {
        guard running else { return }
        cadence.wake(at: ProcessInfo.processInfo.systemUptime)
        step()
    }

    func stop() {
        running = false
        link?.invalidate(); link = nil; retry?.invalidate(); retry = nil
        screenNumber = nil; timerInterval = nil; tick = nil; cadence = WindowFollowCadence()
    }
}
