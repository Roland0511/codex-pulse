import AppKit
import QuartzCore

/// Poll geometry on display refreshes, including AppKit's mouse-tracking run-loop mode.
/// Hidden/minimized hosts use a slow retry timer; manual hiding stops both clocks.
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
    private var screenNumber: NSNumber?
    private var tick: (() -> Bool)?
    private(set) var running = false

    init() { target.owner = self }

    func start(on screen: NSScreen?, tick: @escaping () -> Bool) {
        stop()
        self.tick = tick; running = true
        useScreen(screen)
        step()
    }

    func useScreen(_ screen: NSScreen?) {
        guard running, let screen else { return }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard link == nil || number != screenNumber else { return }
        let paused = retry != nil
        link?.invalidate(); screenNumber = number
        let next = screen.displayLink(target: target, selector: #selector(Target.step))
        let rate = Float(max(60, screen.maximumFramesPerSecond))
        next.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        next.isPaused = paused
        next.add(to: .main, forMode: .common)
        link = next
    }

    private func step() {
        guard running else { return }
        let active = tick?() == true
        guard running else { return }
        if active {
            retry?.invalidate(); retry = nil; link?.isPaused = false
        } else {
            link?.isPaused = true
            if retry == nil {
                let timer = Timer(timeInterval: 0.25, target: target, selector: #selector(Target.step), userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .common); retry = timer
            }
        }
    }

    func refresh() { step() }

    func stop() {
        running = false
        link?.invalidate(); link = nil; retry?.invalidate(); retry = nil
        screenNumber = nil; tick = nil
    }
}
