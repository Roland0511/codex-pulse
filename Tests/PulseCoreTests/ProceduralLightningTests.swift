import Foundation
import Testing
@testable import PulseCore

@Suite("程序化电弧") struct ProceduralLightningTests {
    @Test func seededTopologyIsStableAndTimeIsContinuous() {
        let a = ProceduralLightning.make(seed: 42, length: 28, amplitude: 3, phase: 0.4)
        let b = ProceduralLightning.make(seed: 42, length: 28, amplitude: 3, phase: 0.4001)
        let later = ProceduralLightning.make(seed: 42, length: 28, amplitude: 3, phase: 0.9)
        #expect(a == ProceduralLightning.make(seed: 42, length: 28, amplitude: 3, phase: 0.4))
        #expect(a != later && a != ProceduralLightning.make(seed: 43, length: 28, amplitude: 3, phase: 0.4))
        #expect(a.trunk.count == b.trunk.count && a.branch.count == b.branch.count)
        for (old, next) in zip(a.trunk + a.branch, b.trunk + b.branch) {
            #expect(abs(old.x - next.x) < 0.01 && abs(old.y - next.y) < 0.01)
        }
    }
    @Test func allSeedsStayBoundedOnShortAndFullTracks() {
        for length in [0.01, 1, 2, 16, 28, 180] {
            for seed in 0..<64 {
                for phase in [0.0, 0.3, 0.6, 1] {
                    let bolt = ProceduralLightning.make(seed: UInt64(seed), length: length, amplitude: 3, phase: phase)
                    #expect(bolt.trunk.first == CGPoint(x: length, y: 0) && bolt.trunk.last == .zero)
                    #expect(bolt.trunk.contains(bolt.branch[0]))
                    for point in bolt.trunk + bolt.branch {
                        #expect(point.x.isFinite && point.y.isFinite)
                        #expect(point.x >= 0 && point.x <= length && abs(point.y) <= min(3, length * 0.25))
                    }
                    #expect(zip(bolt.trunk, bolt.trunk.dropFirst()).allSatisfy { $0.x > $1.x })
                }
            }
        }
    }
    @Test func invalidGeometryProducesNoPaths() {
        for (length, amplitude, phase) in [(0.0, 3.0, 0.0), (-1, 3, 0), (.infinity, 3, 0), (28, -1, 0), (28, 3, .nan)] {
            #expect(ProceduralLightning.make(seed: 1, length: length, amplitude: amplitude, phase: phase).trunk.isEmpty)
        }
    }
    @Test func shortFilledSegmentsReduceDetailAndKeepSpeedHierarchy() throws {
        let short = try #require(LightningLayout(filledWidth: 34, tier: .ultrafast))
        let long = try #require(LightningLayout(filledWidth: 180, tier: .ultrafast))
        #expect(short.channels == 1 && !short.forks && short.subdivisions < long.subdivisions)
        #expect(long.channels > short.channels && long.forks)
        #expect(short.amplitude < long.amplitude && short.glowRadius < long.glowRadius)
        let fast = try #require(LightningLayout(filledWidth: 34, tier: .fast))
        #expect(short.duration > fast.duration && short.amplitude > fast.amplitude)
        for width in [3.0, 7, 12, 28, 34, 64, 100, 180] {
            for tier in [SpeedTier.fast, .ultrafast] {
                let style = try #require(LightningLayout(filledWidth: width, tier: tier))
                for phase in [0.0, 0.3, 0.6, 1] {
                    let bolt = ProceduralLightning.make(seed: 42, length: style.length, amplitude: style.amplitude,
                                                        phase: phase, subdivisions: style.subdivisions)
                    #expect(bolt.trunk.allSatisfy { $0.x >= 0 && $0.x <= width && abs($0.y) <= style.amplitude })
                    if width <= DesignTokens.lightningMicroMaxWidth {
                        #expect(bolt.trunk.count == 2 && bolt.trunk.allSatisfy { $0.y == 0 } && bolt.branch.isEmpty)
                    }
                }
            }
        }
        #expect(LightningLayout(filledWidth: .infinity, tier: .ultrafast) == nil)
        #expect(LightningLayout(filledWidth: 1, tier: .ultrafast) == nil)
    }
}
