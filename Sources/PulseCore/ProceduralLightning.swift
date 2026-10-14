import Foundation

/// A small, deterministic fractal discharge. Time changes displacement continuously,
/// preserving point order and branch topology so Core Animation can morph the paths.
public struct ProceduralLightning: Sendable, Equatable {
    public let trunk: [CGPoint]
    public let branch: [CGPoint]

    public static func make(seed: UInt64, length: Double, amplitude: Double, phase: Double, subdivisions: Int? = nil) -> Self {
        guard length.isFinite, amplitude.isFinite, phase.isFinite, length > 0, amplitude >= 0 else {
            return Self(trunk: [], branch: [])
        }
        let depth = subdivisions ?? Int(DesignTokens.lightningSubdivisions)
        guard (0...8).contains(depth) else { return Self(trunk: [], branch: []) }
        let extent = min(amplitude, length * 0.25)
        func noise(_ node: UInt64, _ salt: UInt64) -> Double {
            // SplitMix64: isolated seed, no process-wide random state or wall clock.
            var bits = seed &+ node &* 0x9E3779B97F4A7C15 &+ salt
            bits = (bits ^ (bits >> 30)) &* 0xBF58476D1CE4E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D049BB133111EB
            return Double((bits ^ (bits >> 31)) >> 11) / 9_007_199_254_740_992
        }
        func displacement(_ node: UInt64) -> Double {
            let base = noise(node, 0) * 2 - 1
            let drift = sin(phase * .pi * 2 * (0.45 + noise(node, 1)) + noise(node, 2) * .pi * 2)
            return base * (1 - DesignTokens.lightningTemporalDrift) + drift * DesignTokens.lightningTemporalDrift
        }
        func subdivide(_ a: CGPoint, _ b: CGPoint, _ depth: Int, _ node: UInt64, _ offset: Double,
                       _ lower: Double, _ upper: Double) -> [CGPoint] {
            guard depth > 0 else { return [a, b] }
            let x = (a.x + b.x) / 2 + (b.x - a.x) * (noise(node, 3) - 0.5) * 0.18
            let y = min(upper, max(lower, (a.y + b.y) / 2 + displacement(node) * offset))
            let middle = CGPoint(x: x, y: y)
            let next = offset * DesignTokens.lightningDisplacementDecay
            return Array(subdivide(a, middle, depth - 1, node &* 2, next, lower, upper).dropLast())
                + subdivide(middle, b, depth - 1, node &* 2 &+ 1, next, lower, upper)
        }
        let trunk = subdivide(CGPoint(x: length, y: 0), .zero, depth,
                              1, extent, -extent, extent)
        guard depth > 0 else { return Self(trunk: trunk, branch: []) }
        let fork = trunk[Int(Double(trunk.count - 1) * (0.3 + noise(90, 0) * 0.3))]
        let direction = noise(91, 0) < 0.5 ? -1.0 : 1.0
        let tip = CGPoint(x: max(0, fork.x - length * DesignTokens.lightningBranchLengthFraction),
                          y: direction * extent)
        let branch = subdivide(fork, tip, 2, 100, extent * 0.25, -extent, extent)
        return Self(trunk: trunk, branch: branch)
    }
}

/// Detail follows the filled segment, including low quota in an otherwise wide card.
public struct LightningLayout: Sendable {
    public let length: Double, amplitude: Double, duration: Double, haloWidth: Double, glowRadius: Double, strokeWidth: Double, opacity: Double
    public let channels: Int, subdivisions: Int
    public let forks: Bool
    public init?(filledWidth: Double, tier: SpeedTier) {
        guard filledWidth.isFinite, filledWidth > 0, tier == .fast || tier == .ultrafast else { return nil }
        let strong = tier == .ultrafast
        let compact = filledWidth <= DesignTokens.lightningCompactMaxWidth
        let fullStroke = strong ? DesignTokens.ultrafastLightningStrokeWidth : DesignTokens.fastLightningStrokeWidth
        strokeWidth = fullStroke * (compact ? DesignTokens.lightningCompactStrokeBoost : 1)
        let fullOpacity = strong ? DesignTokens.ultrafastLightningOpacity : DesignTokens.fastLightningOpacity
        opacity = min(1, fullOpacity * (compact ? DesignTokens.lightningCompactOpacityBoost : 1))
        let available = filledWidth - max(0.5, strokeWidth / 2) * 2
        guard available > 1 else { return nil }
        let micro = filledWidth <= DesignTokens.lightningMicroMaxWidth
        let fullLength = strong ? DesignTokens.ultrafastLightningLength : DesignTokens.fastLightningLength
        let fullAmplitude = strong ? DesignTokens.ultrafastLightningAmplitude : DesignTokens.fastLightningAmplitude
        length = min(available, fullLength, compact && !micro ? filledWidth * DesignTokens.lightningCompactLengthFraction : available)
        amplitude = micro ? 0 : min(fullAmplitude, compact ? DesignTokens.lightningCompactAmplitude * (strong ? 1.2 : 1) : fullAmplitude)
        channels = compact ? 1 : Int(strong ? DesignTokens.ultrafastLightningChannels : DesignTokens.fastLightningChannels)
        forks = !compact
        subdivisions = micro ? 0 : compact
            ? min(Int(DesignTokens.lightningSubdivisions), max(1, Int(log2(max(1, length / DesignTokens.lightningSegmentLength)))))
            : Int(DesignTokens.lightningSubdivisions)
        let fullDuration = strong ? DesignTokens.ultrafastLightningBurstSeconds : DesignTokens.fastLightningBurstSeconds
        duration = fullDuration * (micro ? 0.5 : compact ? DesignTokens.lightningCompactBurstScale : 1)
        haloWidth = micro ? 1.25 : compact ? DesignTokens.lightningCompactHaloWidth : 2.8
        glowRadius = micro ? 0.25 : compact ? DesignTokens.lightningCompactGlowRadius
            : strong ? DesignTokens.ultrafastLightningGlowRadius : DesignTokens.fastLightningGlowRadius
    }
}
