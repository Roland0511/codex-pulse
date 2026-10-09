import AppKit
import PulseCore
import QuartzCore
import SwiftUI

/// 系统合成细线动画；应用不逐帧修改共享模型或重绘整个胶囊。
struct AnimatedConsumptionTrace: NSViewRepresentable {
    let signal: Color
    func makeNSView(context: Context) -> ConsumptionTraceLayerView { ConsumptionTraceLayerView() }
    func updateNSView(_ view: ConsumptionTraceLayerView, context: Context) { view.setSignal(NSColor(signal)) }
}

@MainActor final class ConsumptionTraceLayerView: NSView {
    private let moving = CALayer(), head = CALayer(), trail = CAGradientLayer()
    private var dots: [CALayer] = []
    private var signal = NSColor.controlAccentColor
    private let beganAt = CACurrentMediaTime()
    private var animatedWidth: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        moving.anchorPoint = CGPoint(x: 0, y: 0.5)
        moving.bounds = CGRect(x: 0, y: 0, width: DesignTokens.consumptionHeadWidth * 2, height: 2)
        moving.opacity = 0; layer?.addSublayer(moving)
        let axisY = moving.bounds.midY
        trail.frame = CGRect(x: 0, y: axisY - 0.6, width: DesignTokens.consumptionHeadWidth * 2, height: 1.2)
        trail.cornerRadius = 0.6
        trail.startPoint = CGPoint(x: 0, y: 0.5); trail.endPoint = CGPoint(x: 1, y: 0.5)
        trail.locations = [0, 0.5, 1]; moving.addSublayer(trail)
        head.frame = CGRect(x: -0.5, y: axisY - 0.5, width: 1, height: 1)
        head.cornerRadius = 0.5; head.backgroundColor = NSColor.white.cgColor; moving.addSublayer(head)
        for index in 1...4 {
            let dot = CALayer()
            dot.frame = CGRect(x: Double(index) * 5, y: axisY - 0.35, width: 0.7, height: 0.7)
            dot.cornerRadius = 0.35; dot.opacity = Float(1 - Double(index) / 5)
            moving.addSublayer(dot); dots.append(dot)
        }
        setSignal(signal)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func setSignal(_ color: NSColor) {
        signal = color
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trail.colors = [NSColor.white.cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        for dot in dots { dot.backgroundColor = color.cgColor }
        CATransaction.commit()
    }
    override func layout() { super.layout(); configureAnimation() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            moving.removeAllAnimations()
        } else { configureAnimation() }
    }
    private func configureAnimation() {
        guard window != nil, bounds.width > 0,
              bounds.width != animatedWidth || moving.animation(forKey: "flow") == nil else { return }
        animatedWidth = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        moving.position = CGPoint(x: bounds.width, y: bounds.midY)
        CATransaction.commit()
        let laps = max(1, Int(DesignTokens.consumptionLaps))
        var times: [NSNumber] = [0], positions: [CGFloat] = [0]
        for lap in 1...laps {
            let phase = Double(lap) / Double(laps)
            times.append(NSNumber(value: lap == laps ? 1 : phase - 0.000001)); positions.append(-bounds.width)
            if lap != laps { times.append(NSNumber(value: phase)); positions.append(0) }
        }
        let movement = CAKeyframeAnimation(keyPath: "transform.translation.x")
        movement.values = positions; movement.keyTimes = times; movement.calculationMode = .linear
        movement.duration = DesignTokens.consumptionSeconds
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        var fadeTimes: [NSNumber] = [], opacities: [Float] = []
        for lap in 0..<laps {
            // 每次位置回到右端前都已透明，避免中间两圈出现可见跳回。
            for (fraction, opacity) in [(0.0, Float(0)), (DesignTokens.consumptionFadeInEndFraction, 1),
                                        (DesignTokens.consumptionFadeOutStartFraction, 1),
                                        (DesignTokens.consumptionFadeOutEndFraction, 0)] {
                fadeTimes.append(NSNumber(value: (Double(lap) + fraction) / Double(laps)))
                opacities.append(opacity)
            }
        }
        fadeTimes.append(1); opacities.append(0)
        fade.values = opacities; fade.keyTimes = fadeTimes
        fade.calculationMode = .linear
        fade.duration = DesignTokens.consumptionSeconds
        let group = CAAnimationGroup()
        group.animations = [movement, fade]; group.duration = DesignTokens.consumptionSeconds
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.repeatCount = .infinity; group.beginTime = moving.convertTime(beganAt, from: nil)
        moving.add(group, forKey: "flow")
    }
}
