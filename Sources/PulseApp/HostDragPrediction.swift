import Foundation

/// Only activates after real host movement matches recent pointer movement.
/// Content selection and unrelated drags never move the capsule speculatively.
struct HostDragPrediction {
    private let anchor: CodexWindow
    private let began: CGPoint
    private var samples: [(point: CGPoint, time: Double)]
    private(set) var confirmed = false
    init(window: CodexWindow, point: CGPoint, time: Double) {
        anchor = window; began = point; samples = [(point, time)]
    }
    mutating func record(_ point: CGPoint, at time: Double) {
        samples.append((point, time))
        samples.removeAll { time - $0.time > 0.08 }
    }
    mutating func reconcile(_ window: CodexWindow, at time: Double) -> CGRect? {
        guard window.id == anchor.id, window.frame.size == anchor.frame.size, window.isOnScreen,
              let latest = samples.last, time - latest.time < 0.1 else { confirmed = false; return nil }
        let delta = CGPoint(x: window.frame.minX - anchor.frame.minX, y: window.frame.minY - anchor.frame.minY)
        let matches = samples.contains { sample in
            time - sample.time <= 0.08 && hypot(sample.point.x - began.x - delta.x, sample.point.y - began.y - delta.y) <= 3
        }
        guard matches, hypot(delta.x, delta.y) >= 2 else { confirmed = false; return nil }
        let lead = hypot(latest.point.x - began.x - delta.x, latest.point.y - began.y - delta.y)
        guard lead <= 96 else { confirmed = false; return nil }
        confirmed = true
        return anchor.frame.offsetBy(dx: latest.point.x - began.x, dy: latest.point.y - began.y)
    }
    var predictedFrame: CGRect? {
        guard confirmed, let latest = samples.last else { return nil }
        return anchor.frame.offsetBy(dx: latest.point.x - began.x, dy: latest.point.y - began.y)
    }
}
