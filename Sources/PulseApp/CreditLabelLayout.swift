import AppKit
import PulseCore

/// 测量与 SwiftUI 使用同一个原生字体，避免 fixedSize 数字反向撑大胶囊。
struct CreditLabelLayout {
    let text: String
    let font: NSFont
    let measuredWidth: CGFloat

    static func fit(_ balance: Decimal, width: CGFloat, decimalPlaces: Int = 1, expanded: Bool = false, maximumFontSize: CGFloat = 14) -> Self {
        let compact = CreditText.candidates(balance, decimalPlaces: decimalPlaces)
        let candidates = expanded ? [CreditText.expanded(balance, decimalPlaces: decimalPlaces)] + compact : compact
        let ordinary = candidates.filter { !$0.contains("e") }
        let scientific = candidates.filter { $0.contains("e") }
        for group in [ordinary, scientific] {
            for candidate in group {
                for size in [14.0, 13.0, 12.0] where size <= maximumFontSize {
                    let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
                    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
                    let measured = ceil((candidate as NSString).size(withAttributes: [.font: font]).width)
                    if measured <= width { return Self(text: candidate, font: font, measuredWidth: measured) }
                }
            }
        }
        // 最窄的合法胶囊仍为 38 pt；Decimal 的科学计数候选在此宽度内可容纳。
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let label = candidates.last ?? "—"
        return Self(text: label, font: font,
                    measuredWidth: ceil((label as NSString).size(withAttributes: [.font: font]).width))
    }
}
