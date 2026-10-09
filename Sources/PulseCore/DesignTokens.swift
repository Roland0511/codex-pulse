// 由 scripts/generate_tokens.py 生成；请修改 design/v0.1/tokens.json。
import Foundation

public enum DesignTokens {
    public static let capsuleWidth: Double = 180
    public static let height: Double = 36
    public static let dockedWidth: Double = 54
    public static let detailsWidth: Double = 264
    public static let dockedExpandedWidth: Double = 204
    public static let joinRadius: Double = 8
    public static let outerRadius: Double = 10
    public static let outlineWidth: Double = 0.65
    public static let dragThreshold: Double = 5
    public static let attachmentTravel: Double = 32
    public static let expandSeconds: Double = 0.2
    public static let hoverLeaveSeconds: Double = 0.4
    public static let barSeconds: Double = 0.36
    public static let recoverySeconds: Double = 0.52
    public static let consumptionSeconds: Double = 3.2
    public static let consumptionLaps: Double = 3
    public static let consumptionHeadWidth: Double = 18
    public static let consumptionFadeInEndFraction: Double = 0.12
    public static let consumptionFadeOutStartFraction: Double = 0.8
    public static let consumptionFadeOutEndFraction: Double = 0.98
    public static let peakOutlineWidth: Double = 1.8
    public static let peakHoldFraction: Double = 0.18
    public static let percentageOnlyBelowWidth: Double = 100
    public static let countdownRevealFrom: Double = 164
    public static let countdownRevealTo: Double = 180
    public static let surfaceLight: UInt32 = 0xfcfdfd
    public static let surfaceDark: UInt32 = 0x1b2025
    public static let inkLight: UInt32 = 0x19242b
    public static let inkDark: UInt32 = 0xedf5f5
    public static let mutedLight: UInt32 = 0x63727a
    public static let mutedDark: UInt32 = 0xa4b4bb
    public static let edgeLight: UInt32 = 0xdbe4e7
    public static let edgeDark: UInt32 = 0x38434a
    public static let signalLight: UInt32 = 0x007b71
    public static let signalDark: UInt32 = 0x6ee4ce
    public static let trackLight: UInt32 = 0xe3eeeb
    public static let trackDark: UInt32 = 0x2d3e3c
    public static let expandCurve: [Double] = [0.2, 0.85, 0.25, 1]
}
