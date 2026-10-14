import AppKit
import PulseCore
import QuartzCore
import SwiftUI

/// 系统合成细线动画；应用不逐帧修改共享模型或重绘整个胶囊。
struct AnimatedConsumptionTrace: NSViewRepresentable {
    let signal: Color
    let surface: Color
    @Environment(\.self) private var environment
    var speed: SpeedTier = .standard
    func makeNSView(context: Context) -> ConsumptionTraceLayerView { ConsumptionTraceLayerView() }
    func updateNSView(_ view: ConsumptionTraceLayerView, context: Context) {
        // Dynamic NSColor providers need the same drawing appearance as SwiftUI,
        // including when the representable's AppKit effectiveAppearance differs.
        let appearance = NSAppearance(named: environment.colorScheme == .dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            let background = surface.resolve(in: environment)
            view.setSurface(NSColor(srgbRed: Double(background.red), green: Double(background.green),
                                    blue: Double(background.blue), alpha: Double(background.opacity)))
            view.setSignal(NSColor(signal))
        }
        view.setSpeed(speed)
    }
}

@MainActor final class ConsumptionTraceLayerView: NSView {
    private(set) var filled = CALayer()
    private let moving = CALayer(), head = CALayer(), trail = CAGradientLayer()
    private var dots: [CALayer] = []
    private var signal = NSColor.controlAccentColor
    private var darkSurface = false
    private let beganAt = CACurrentMediaTime()
    private var animatedWidth: CGFloat = 0
    private var animatedHeight: CGFloat = 0
    private(set) var speed = SpeedTier.standard
    private(set) var arcs: [CAShapeLayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        filled.name = "filled-track"; layer?.addSublayer(filled)
        moving.name = "moving-flow"; head.name = "flow-head"
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
    func setSurface(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let dark = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.45
        guard dark != darkSurface else { return }
        darkSurface = dark
        for arc in arcs { colorize(arc) }
    }
    func setSignal(_ color: NSColor) {
        signal = color
        CATransaction.begin(); CATransaction.setDisableActions(true)
        filled.backgroundColor = color.cgColor
        trail.colors = [NSColor.white.cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        for dot in dots { dot.backgroundColor = color.cgColor }
        CATransaction.commit()
        for arc in arcs { colorize(arc) }
    }
    func setSpeed(_ value: SpeedTier) {
        guard value != speed else { return }
        let old = arcs; arcs = []; speed = value
        let duration = DesignTokens.lightningTransitionSeconds
        for arc in old {
            let currentOpacity = arc.presentation()?.opacity ?? 0
            arc.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = currentOpacity; fade.toValue = 0
            fade.duration = duration; arc.opacity = 0; arc.add(fade, forKey: "leave")
        }
        // Keep the transient layers bounded even during repeated speed changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { for arc in old { arc.removeFromSuperlayer() } }
        configureTrack()
        configureLightning()
    }
    override func layout() { super.layout(); configureTrack(); configureAnimation() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); configureTrack()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for arc in arcs { colorize(arc) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            moving.removeAllAnimations()
            for arc in arcs { arc.removeAllAnimations() }
        } else { configureTrack(); configureAnimation() }
    }
    private func configureTrack() {
        let height = speed == .ultrafast ? DesignTokens.ultrafastLightningCoreHeight
            : speed == .fast ? DesignTokens.fastLightningCoreHeight : 2
        let scale = window?.backingScaleFactor ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The base and the moving light share one native coordinate system. Mixing a
        // SwiftUI capsule with an NSView overlay can independently round half-point origins.
        filled.frame = CGRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
        filled.cornerRadius = height / 2
        for item in [layer, filled, moving, trail, head] + dots.map(Optional.some) + arcs.map(Optional.some) {
            item?.contentsScale = scale
        }
        CATransaction.commit()
    }
    private func configureAnimation() {
        guard window != nil, bounds.width > 0,
              bounds.width != animatedWidth || bounds.height != animatedHeight || moving.animation(forKey: "flow") == nil else { return }
        animatedWidth = bounds.width
        animatedHeight = bounds.height
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
        configureLightning()
    }

    private func colorize(_ arc: CAShapeLayer) {
        let halo = arc.name?.hasSuffix("halo") == true
        let dark = darkSurface
        func color(_ light: UInt32, _ darkColor: UInt32) -> CGColor {
            let hex = dark ? darkColor : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1).cgColor
        }
        let glow = color(DesignTokens.lightningHaloLight, DesignTokens.lightningHaloDark)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.strokeColor = halo ? glow : color(DesignTokens.lightningCoreLight, DesignTokens.lightningCoreDark)
        arc.shadowColor = glow
        CATransaction.commit()
    }

    private func configureLightning() {
        guard window != nil, bounds.width > 0 else { return }
        for arc in arcs { arc.removeFromSuperlayer() }; arcs = []
        guard speed == .fast || speed == .ultrafast else { return }
        let strong = speed == .ultrafast
        let starts = strong ? DesignTokens.ultrafastLightningBurstStartsSeconds : DesignTokens.fastLightningBurstStartsSeconds
        guard let detail = LightningLayout(filledWidth: bounds.width, tier: speed) else { return }
        let duration = detail.duration
        let width = detail.strokeWidth
        let inset = max(0.5, width / 2)
        let length = detail.length
        guard length > 1 else { return }
        let amplitude = min(bounds.midY - inset, detail.amplitude)
        let opacity = detail.opacity
        let channels = detail.channels
        let branchOpacity = strong ? DesignTokens.ultrafastLightningBranchOpacity : DesignTokens.fastLightningBranchOpacity
        let haloOpacity = strong ? DesignTokens.ultrafastLightningHaloOpacity : DesignTokens.fastLightningHaloOpacity
        let cycle = DesignTokens.lightningCycleSeconds
        let epoch = CACurrentMediaTime()
        // Each burst has its own seeded fractal, a coherent path morph and a travelling
        // stroke. All keyframes are prebuilt; the compositor advances them without a timer.
        for (index, start) in starts.enumerated() {
            for channel in 0..<channels {
                let seed = UInt64(index * channels + channel + 1) &* 0x9E3779B97F4A7C15
                let channelLength = length * (channel == 0 ? 1 : 0.82)
                let spread = Double(index * channels + channel + 1) * 0.61803398875
                let x = inset + (bounds.width - inset * 2 - channelLength) * (spread - floor(spread))
                let bolts = [0.0, 0.3, 0.6, 1.0].map {
                    ProceduralLightning.make(seed: seed, length: channelLength, amplitude: max(0, amplitude), phase: $0,
                                             subdivisions: detail.subdivisions)
                }
                for branch in [false, true] where !branch || detail.forks {
                    let paths: [CGPath] = bolts.map { bolt in
                        let path = CGMutablePath()
                        path.addLines(between: (branch ? bolt.branch : bolt.trunk).map { CGPoint(x: x + $0.x, y: bounds.midY + $0.y) })
                        return path
                    }
                    for halo in [true, false] {
                        let arc = CAShapeLayer()
                        arc.name = (branch ? "branch-" : "trunk-") + (halo ? "halo" : "core")
                        arc.frame = bounds; arc.path = paths[0]; arc.fillColor = nil
                        arc.lineWidth = width * (branch ? 0.55 : 1) * (halo ? detail.haloWidth : 1) * (channel == 0 ? 1 : 0.7)
                        arc.lineJoin = .round; arc.lineCap = .round; arc.opacity = 0
                        arc.contentsScale = window?.backingScaleFactor ?? 1
                        arc.shadowRadius = halo ? detail.glowRadius : 0
                        arc.shadowOpacity = halo ? 0.65 : 0; arc.shadowOffset = .zero
                        colorize(arc); layer?.addSublayer(arc); arcs.append(arc)
                        let delay = (branch ? duration * 0.18 : 0) + (channel == 0 ? 0 : duration * 0.14)
                        let onset = start + delay
                        let lifetime = duration - delay
                        let peak = opacity * (halo ? haloOpacity : 1) * (branch ? branchOpacity : 1) * (channel == 0 ? 1 : 0.75)
                        func keyframes(_ key: String, _ entries: [(Double, Any)]) -> CAKeyframeAnimation {
                            let animation = CAKeyframeAnimation(keyPath: key)
                            animation.keyTimes = entries.map { NSNumber(value: $0.0 / cycle) }
                            animation.values = entries.map { $0.1 }
                            animation.calculationMode = .linear; animation.duration = cycle
                            return animation
                        }
                        let fade = keyframes("opacity", [(0, 0), (onset, 0), (onset + lifetime * 0.1, peak * 0.4),
                            (onset + lifetime * 0.24, peak), (onset + lifetime * 0.38, peak * 0.55),
                            (onset + lifetime * 0.52, peak * 0.8), (onset + lifetime * 0.72, peak * 0.3),
                            (onset + lifetime, 0), (cycle, 0)])
                        let front = keyframes("strokeEnd", [(0, 0), (onset, 0), (onset + lifetime * 0.36, 1), (cycle, 1)])
                        let tail = keyframes("strokeStart", [(0, 0), (onset + lifetime * 0.24, 0), (onset + lifetime * 0.94, 1), (cycle, 1)])
                        let morph = keyframes("path", [(0, paths[0]), (start, paths[0]), (start + duration * 0.3, paths[1]),
                            (start + duration * 0.6, paths[2]), (start + duration, paths[3]), (cycle, paths[3])])
                        let group = CAAnimationGroup()
                        group.animations = [fade, front, tail, morph]; group.duration = cycle
                        group.repeatCount = .infinity; group.beginTime = arc.convertTime(epoch, from: nil)
                        arc.add(group, forKey: "lightning")
                    }
                }
            }
        }
    }

}

/// Both compact and expanded quota tracks share the same fill/effect geometry.
struct QuotaProgressTrack: View {
    let remaining: Double?
    let color: Color
    let track: Color
    let surface: Color
    let animating: Bool
    let speed: SpeedTier
    let reduceMotion: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if let remaining {
                    ZStack {
                        if animating && !reduceMotion && remaining > 0 {
                            AnimatedConsumptionTrace(signal: color, surface: surface, speed: speed)
                                .frame(height: DesignTokens.lightningEffectHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 1))
                                .accessibilityHidden(true)
                        } else { Capsule().fill(color).frame(height: 2) }
                    }
                    .frame(width: geometry.size.width * remaining / 100, height: 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: DesignTokens.barSeconds), value: remaining)
                }
            }
        }.frame(height: 2).accessibilityHidden(true)
    }
}
