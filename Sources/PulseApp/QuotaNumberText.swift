import SwiftUI
import PulseCore

/// 仅在服务确认的新数值到达时过渡字形，不逐帧修改账户数据或重建整个卡片。
struct QuotaNumberText: View {
    let text: String
    let value: Double?
    let font: Font
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(font)
            .contentTransition(.numericText(value: value ?? 0))
            .animation(animate && !reduceMotion ? .easeOut(duration: DesignTokens.barSeconds) : nil, value: text)
    }
}
