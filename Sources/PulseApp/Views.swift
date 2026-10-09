import AppKit
import PulseCore
import SwiftUI

struct CapsuleContour: Shape {
    var side: DockSide?
    var blend: Double
    var openEdge = false
    var animatableData: Double { get { blend } set { blend = newValue } }
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, o = min(DesignTokens.outerRadius, h / 2), r = DesignTokens.joinRadius
        let left = side == .left ? blend : 0, right = side == .right ? blend : 0
        let yl = o - (o + r) * left, yr = o - (o + r) * right
        let xl = o + (r - o) * left, xr = o + (r - o) * right
        var p = Path()
        if openEdge && side == .right {
            p.move(to: CGPoint(x: w, y: yr))
            p.addQuadCurve(to: CGPoint(x: w - xr, y: 0), control: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: xl, y: 0))
            p.addQuadCurve(to: CGPoint(x: 0, y: yl), control: .zero)
            p.addLine(to: CGPoint(x: 0, y: h - yl))
            p.addQuadCurve(to: CGPoint(x: xl, y: h), control: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: w - xr, y: h))
            p.addQuadCurve(to: CGPoint(x: w, y: h - yr), control: CGPoint(x: w, y: h))
        } else {
            p.move(to: CGPoint(x: 0, y: yl))
            p.addQuadCurve(to: CGPoint(x: xl, y: 0), control: .zero)
            p.addLine(to: CGPoint(x: w - xr, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: yr), control: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h - yr))
            p.addQuadCurve(to: CGPoint(x: w - xr, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: xl, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - yl), control: CGPoint(x: 0, y: h))
            if !(openEdge && side == .left) { p.closeSubpath() }
        }
        return p
    }
}

struct OverlayView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var model: OverlayModel
    @ObservedObject private var appearance = AppearanceStore.shared
    private var palette: Palette { appearance.palette }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var refreshFocused: Bool
    private var selected: QuotaWindow? { store.state.snapshot?.selectedWindow }
    private var showsPin: Bool { model.side != nil && model.width >= DesignTokens.countdownRevealFrom }
    private var restricted: Bool { store.state.snapshot?.ordinaryUsageAllowed == false || store.state.snapshot?.hasReachedLimit == true }
    private var tint: Color {
        guard store.status == .ready, !restricted, let remaining = selected?.remainingPercent else { return palette.muted }
        return remaining <= 10 ? palette.danger : remaining <= 20 ? palette.warning : palette.signal
    }
    private var statusText: String {
        if store.demo, store.status == .ready { return "演示数据" }
        let prefix = store.demo ? "演示 · " : ""
        switch store.status {
        case .loading: return prefix + "读取中"
        case .ready: return restricted ? "额度受限" : "剩余额度"
        case .unavailable: return prefix + "额度不可用"
        case .unauthenticated: return prefix + "未登录"
        case .failed: return prefix + "连接异常"
        case .stale: return prefix + "数据已过期"
        }
    }
    private var percentage: String {
        if let selected { return QuotaText.percentage(selected.remainingPercent) }
        return store.status == .loading ? "···" : "—"
    }
    private var emptyWindowMessage: String {
        store.state.error?.message ?? (store.status == .loading ? "正在读取额度…" : "服务未返回可用窗口")
    }
    private var accessibilitySummary: String {
        guard let selected else { return "\(statusText)。\(emptyWindowMessage)" }
        return "\(statusText)，\(selected.name)，剩余 \(percentage)，\(QuotaText.countdown(selected.resetsAt, now: store.now))" +
            (model.consumptionDetected ? "，\(model.consumptionMessage)" : "")
    }
    var body: some View {
        ZStack(alignment: .top) {
            CapsuleContour(side: model.side, blend: model.blend)
                .fill(palette.surface)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            CapsuleContour(side: model.side, blend: model.blend)
                .stroke(palette.edge, lineWidth: DesignTokens.outlineWidth)
            if model.flash > 0 {
                CapsuleContour(side: model.side, blend: model.blend, openEdge: model.side != nil)
                    .stroke(palette.signal.opacity(model.flash), lineWidth:
                                DesignTokens.outlineWidth + (DesignTokens.peakOutlineWidth - DesignTokens.outlineWidth) * model.flash)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                header
                if model.expanded { details }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.outerRadius))
        }
        .frame(width: model.width, height: model.height)
        .padding(16)
        .onChange(of: model.keyboardOpened) { _, opened in if opened { refreshFocused = true } }
        .onExitCommand { model.close?() }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 7) {
                Text(percentage).font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(palette.ink).fixedSize()
                if store.status != .ready || restricted || store.demo {
                    Image(systemName: store.demo ? "eye" : "exclamationmark.circle").font(.system(size: 10))
                        .foregroundStyle(palette.warning)
                        .opacity(model.width < DesignTokens.percentageOnlyBelowWidth ? 0 : 1)
                }
                if model.width >= DesignTokens.percentageOnlyBelowWidth {
                    Text(compactDescription).font(.system(size: 10.5)).foregroundStyle(palette.muted)
                        .lineLimit(1).truncationMode(.tail)
                        .opacity(min(1, max(0, (model.width - DesignTokens.countdownRevealFrom) /
                                             (DesignTokens.countdownRevealTo - DesignTokens.countdownRevealFrom))))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, model.width < DesignTokens.percentageOnlyBelowWidth ? 8 : 12)
            .padding(.trailing, showsPin ? 36 : (model.width < DesignTokens.percentageOnlyBelowWidth ? 8 : 12))
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.height - 7)
            .frame(height: DesignTokens.height, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggle?() }
            .accessibilityHint("点击展开全部额度；可从菜单栏调整位置")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    if let value = selected?.remainingPercent {
                        ZStack {
                            Capsule().fill(tint)
                            if model.consumptionAnimating, value > 0 {
                                // 流光与填充段共用宽度和裁切，额度变化时也不越界。
                                AnimatedConsumptionTrace(signal: palette.signal)
                                    .frame(height: 2)
                                    .accessibilityHidden(true)
                            }
                        }
                            .frame(width: geometry.size.width * value / 100, height: 2)
                            .clipShape(Capsule())
                            .animation(reduceMotion ? nil : .easeOut(duration: DesignTokens.barSeconds), value: value)
                    }
                }
            }.frame(height: 2).padding(.horizontal, 10).padding(.bottom, 5)
        }
        .frame(height: DesignTokens.height)
        .contentShape(Rectangle())
        .overlay(DragSurface(model: model).accessibilityHidden(true))
        .overlay(alignment: .topTrailing) {
            if showsPin {
                Button { model.togglePin?() } label: {
                    Image(systemName: model.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.pinned ? palette.signal : palette.muted)
                        .frame(width: 26, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.trailing, 4)
                .accessibilityLabel(model.pinned ? "取消固定长条" : "固定为长条")
                .accessibilityValue(model.pinned ? "已固定" : "未固定")
                .help(model.pinned ? "取消固定，鼠标离开后收回" : "固定为长条，鼠标离开后保持展开")
            }
        }
        .accessibilityElement(children: .contain)
        .help(accessibilitySummary)
    }
    private var compactDescription: String {
        guard store.status == .ready, !restricted, !store.demo else { return statusText }
        if model.consumptionDetected { return "· \(model.consumptionMessage)" }
        guard let selected else { return statusText }
        let countdown = QuotaText.countdown(selected.resetsAt, now: store.now).replacingOccurrences(of: " ", with: "")
        return "· \(countdown)"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(palette.edge)
            HStack {
                Text(statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
                Spacer()
                if model.consumptionDetected {
                    Label(model.consumptionMessage, systemImage: "sparkles").font(.system(size: 9)).foregroundStyle(palette.signal)
                }
                if store.refreshing { Text("刷新中…").font(.system(size: 10)).foregroundStyle(palette.muted) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.state.snapshot?.windows ?? []) { window in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(window.name).font(.system(size: 11)).foregroundStyle(palette.muted)
                                    .lineLimit(2).help(window.name)
                                Spacer(minLength: 6)
                                Text(QuotaText.percentage(window.remainingPercent)).font(.system(size: 15, weight: .medium))
                                    .monospacedDigit().fixedSize()
                            }
                            if let reset = window.resetsAt {
                                Text("重置时间 \(reset.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 10)).foregroundStyle(palette.muted)
                            } else { Text("重置时间未知").font(.system(size: 10)).foregroundStyle(palette.muted) }
                        }.accessibilityElement(children: .combine)
                    }
                    if store.state.snapshot?.windows.isEmpty != false {
                        Text(emptyWindowMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(store.state.error == nil ? palette.muted : palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.automatic)
            if let error = store.state.error, store.state.snapshot?.windows.isEmpty == false {
                Text(error.message).font(.system(size: 10)).foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            if store.state.snapshot?.ordinaryUsageAllowed == false || store.state.snapshot?.hasReachedLimit == true {
                Text("服务报告当前额度受限").font(.system(size: 10)).foregroundStyle(palette.warning)
            }
            if let count = store.state.snapshot?.availableResetCount {
                Text("可用重置次数：\(count)").font(.system(size: 10)).foregroundStyle(palette.muted)
            }
            HStack {
                if let date = store.state.snapshot?.fetchedAt {
                    Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 9)).foregroundStyle(palette.muted)
                }
                Spacer()
                Button("刷新") { store.refresh(manual: true) }.buttonStyle(.plain)
                    .foregroundStyle(palette.signal).disabled(store.refreshing || store.demo)
                    .focused($refreshFocused).keyboardShortcut("r", modifiers: [.command])
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12).foregroundStyle(palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct DragSurface: NSViewRepresentable {
    let model: OverlayModel
    func makeNSView(context: Context) -> HeaderHitView { let view = HeaderHitView(); view.model = model; return view }
    func updateNSView(_ view: HeaderHitView, context: Context) { view.model = model }
}

@MainActor final class HeaderHitView: NSView {
    weak var model: OverlayModel?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { model?.hover?(true) }
    override func mouseExited(with event: NSEvent) { model?.hover?(false) }
    // 使用事件位置；合成桌面输入和高频拖动时全局 mouseLocation 可能仍是上一采样。
    override func mouseDown(with event: NSEvent) { model?.dragBegan?(screenPoint(event)) }
    override func mouseDragged(with event: NSEvent) { model?.dragMoved?(screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { model?.dragEnded?() }
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { model?.close?() }
        else if event.keyCode == 49 || event.keyCode == 36 { model?.toggle?() }
        else { super.keyDown(with: event) }
    }
}
