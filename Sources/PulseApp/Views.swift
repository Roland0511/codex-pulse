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
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject var creditDisplay = CreditDisplayStore.shared
    @ObservedObject var throughput: ThroughputStore
    init(store: QuotaStore, model: OverlayModel, creditDisplay: CreditDisplayStore = .shared) {
        self.store = store; self.model = model; self.creditDisplay = creditDisplay; self.throughput = store.throughput
    }
    private var stackedHeader: Bool {
        model.throughputEnabled && model.throughputLayout == .stacked && model.side != nil &&
            model.width < DesignTokens.percentageOnlyBelowWidth
    }
    private var narrowHeader: Bool { model.width < (model.throughputEnabled ? DesignTokens.countdownRevealFrom : DesignTokens.percentageOnlyBelowWidth) }

    private var text: PulseText { language.text }
    private var palette: Palette { appearance.palette }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || model.reduceMotion }
    @FocusState private var refreshFocused: Bool
    private var selected: QuotaWindow? { store.state.snapshot?.selectedWindow }
    private var creditBalance: Decimal? { store.state.snapshot?.displayMode.creditBalance }
    private var displayedCredits: QuotaCredits? {
        guard case let .credits(bucket, _) = store.state.snapshot?.displayMode else { return nil }
        return store.state.snapshot?.creditsByBucket?[bucket]
    }
    private var fullCredits: String { displayedCredits?.fullBalance ?? "—" }
    private var detailCredits: String {
        creditBalance.map { CreditText.expanded($0, decimalPlaces: creditDisplay.expandedDecimalPlaces) } ?? "—"
    }
    private var numberScope: String {
        guard let snapshot = store.state.snapshot else { return "loading" }
        if case let .credits(bucket, _) = snapshot.displayMode { return snapshot.accountKey + ":credits:" + bucket }
        return snapshot.accountKey + ":window:" + (selected?.id ?? "unknown")
    }
    private var creditLayout: CreditLabelLayout? {
        guard let creditBalance else { return nil }
        let narrow = narrowHeader
        let warning = store.status != .ready || restricted || store.demo
        let available = model.width - (narrow ? 16 : 12 + (showsPin ? 36 : 12))
            - (!narrow && warning ? 17 : 0) - (!narrow ? 7 : 0)
            - (model.throughputEnabled ? (stackedHeader ? 0 : (narrow ? 48 : 68)) : (model.width >= DesignTokens.countdownRevealFrom ? 48 : 0))
        let expanded = model.side != nil && !narrow
        return CreditLabelLayout.fit(creditBalance, width: max(38, available),
            decimalPlaces: expanded ? creditDisplay.expandedDecimalPlaces : creditDisplay.compactDecimalPlaces,
            expanded: expanded, maximumFontSize: stackedHeader ? DesignTokens.stackedQuotaFontSize : 14)
    }
    private var speedTier: SpeedTier {
        store.demo ? store.demoSpeed : store.confirmedSpeedTier ?? appearance.speed.tier
    }
    private var speedSummary: String {
        guard speedTier != .unknown else { return tr("speed.unknown") }
        return tr(store.confirmedSpeedTier != nil || store.demo ? "speed.working" : "speed.default", tr("speed." + speedTier.rawValue))
    }
    private var showsPin: Bool { model.side != nil && model.width >= DesignTokens.countdownRevealFrom }
    private var restricted: Bool { store.state.snapshot?.ordinaryUsageAllowed == false || store.state.snapshot?.hasReachedLimit == true }
    private var hasDataWarning: Bool { (store.status != .ready && store.status != .loading) || restricted }
    private var compactWarning: Bool { narrowHeader && hasDataWarning }
    private var numberColor: Color { hasDataWarning ? palette.muted : palette.ink }
    private var tint: Color {
        if creditBalance != nil { return store.status == .ready && !restricted ? palette.signal : palette.muted }
        guard store.status == .ready, !restricted, let remaining = selected?.remainingPercent else { return palette.muted }
        return remaining <= 10 ? palette.danger : remaining <= 20 ? palette.warning : palette.signal
    }
    private var statusText: String {
        if store.demo, store.status == .ready { return tr("status.demo") }
        let prefix = store.demo ? tr("status.demo.prefix") : ""
        switch store.status {
        case .loading: return prefix + tr("status.loading")
        case .ready: return restricted ? tr("status.restricted") : tr(creditBalance == nil ? "status.remaining" : "credits.remaining")
        case .unavailable: return prefix + tr("status.unavailable")
        case .unauthenticated: return prefix + tr("status.signedOut")
        case .failed: return prefix + tr("status.failed")
        case .stale: return prefix + tr("status.stale")
        }
    }
    private var percentage: String {
        if let selected { return QuotaText.percentage(selected.remainingPercent, using: text) }
        return store.status == .loading ? "···" : "—"
    }
    private var emptyWindowMessage: String {
        store.state.error?.message(using: text) ?? (store.status == .loading ? tr("status.reading") : tr("status.empty"))
    }
    private var accessibilitySummary: String {
        if creditBalance != nil {
            return "\(statusText) · \(tr("credits.remaining")) · \(fullCredits)" +
                (model.working ? " · \(speedSummary)" : "")
        }
        guard let selected else { return "\(statusText) · \(emptyWindowMessage)" }
        return tr("quota.summary", statusText, selected.localizedName(using: text), percentage,
                  QuotaText.countdown(selected.resetsAt, now: store.now, using: text)) +
            (model.consumptionDetected ? " · \(model.consumptionMessage)" : "")
            + (model.working ? " · \(speedSummary)" : "")
    }
    var body: some View {
        ZStack(alignment: .top) {
            CapsuleContour(side: model.side, blend: model.blend)
                .fill(palette.surface)
                .frame(width: model.width, height: model.height)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            CapsuleContour(side: model.side, blend: model.blend)
                .stroke(palette.edge, lineWidth: DesignTokens.outlineWidth)
                .frame(width: model.width, height: model.height)
            if model.flash > 0 {
                CapsuleContour(side: model.side, blend: model.blend, openEdge: model.side != nil)
                    .stroke(palette.signal.opacity(model.flash), lineWidth:
                                DesignTokens.outlineWidth + (DesignTokens.peakOutlineWidth - DesignTokens.outlineWidth) * model.flash)
                    .frame(width: model.width, height: model.height)
                    .allowsHitTesting(false)
            }
            Group {
                if model.expanded { details }
                else { header }
            }
            .frame(width: model.width, height: model.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.outerRadius))
        }
        .frame(width: model.width, height: model.height)
        .padding(16)
        .onChange(of: model.keyboardOpened) { _, opened in if opened { refreshFocused = true } }
        .onExitCommand { model.close?() }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if stackedHeader { stackedThroughputHeader }
                else if model.throughputEnabled { throughputHeader }
                else { quotaHeader }
            }
            .frame(height: DesignTokens.height - 7)
            .frame(height: DesignTokens.height, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary + (model.throughputEnabled ? " · " + throughputAccessibility : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggle?() }
            .accessibilityHint(tr("quota.hint"))
            QuotaProgressTrack(remaining: creditBalance == nil ? selected?.remainingPercent : 100, color: tint, track: palette.track, surface: palette.surface,
                animating: model.consumptionAnimating, speed: speedTier, reduceMotion: reduceMotion)
                .padding(.leading, 10)
                .padding(.trailing, compactWarning ? DesignTokens.compactStatusSize + DesignTokens.compactStatusTrailing + DesignTokens.compactStatusGap : 10)
                .padding(.bottom, 5)
            if compactWarning {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: DesignTokens.compactStatusSize, weight: .semibold))
                    .foregroundStyle(palette.warning)
                    .frame(width: DesignTokens.compactStatusSize, height: DesignTokens.compactStatusSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, DesignTokens.compactStatusTrailing)
                    .padding(.bottom, DesignTokens.compactStatusBottom)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
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
                .accessibilityLabel(model.pinned ? tr("pin.unpin") : tr("pin"))
                .accessibilityValue(model.pinned ? tr("pin.on") : tr("pin.off"))
                .help(model.pinned ? tr("pin.unpin.hint") : tr("pin.hint"))
            }
        }
        .accessibilityElement(children: .contain)
        .help(accessibilitySummary + (model.throughputEnabled ? " · " + throughputAccessibility : ""))
    }
    @ViewBuilder private var quotaNumber: some View {
        if let layout = creditLayout {
            QuotaNumberText(text: layout.text, value: creditBalance.map { NSDecimalNumber(decimal: $0).doubleValue },
                            font: Font(layout.font), animate: store.status == .ready && !reduceMotion)
                .id(numberScope + ":precision:\(creditDisplay.compactDecimalPlaces):\(creditDisplay.expandedDecimalPlaces)")
                .foregroundStyle(numberColor)
                .lineLimit(1).fixedSize().accessibilityIdentifier("quota.creditBalance")
        } else {
            QuotaNumberText(text: percentage, value: selected?.remainingPercent,
                            font: .system(size: stackedHeader ? DesignTokens.stackedQuotaFontSize : 14, weight: .medium, design: .rounded), animate: store.status == .ready && !reduceMotion)
                .id(numberScope).monospacedDigit()
                .foregroundStyle(numberColor).fixedSize()
        }
    }
    private var quotaHeader: some View {
        HStack(spacing: 7) {
            quotaNumber
            if model.width >= DesignTokens.percentageOnlyBelowWidth && (store.status != .ready || restricted || store.demo) {
                Image(systemName: store.demo ? "eye" : "exclamationmark.circle").font(.system(size: 10))
                    .foregroundStyle(palette.warning)
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
    }
    private var stackedThroughputHeader: some View {
        VStack(spacing: 0) {
            quotaNumber.frame(height: DesignTokens.stackedQuotaLineHeight)
            ThroughputInline(presentation: throughput.presentation, narrow: true, stacked: true)
                .frame(width: model.width - 16, height: DesignTokens.stackedSpeedLineHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, DesignTokens.stackedTopPadding)
    }
    private var throughputHeader: some View {
        HStack(spacing: narrowHeader ? 5 : 8) {
            HStack(spacing: 4) {
                quotaNumber
                if !narrowHeader && (hasDataWarning || store.demo) {
                    Image(systemName: store.demo ? "eye" : "exclamationmark.circle")
                        .font(.system(size: 10)).foregroundStyle(palette.warning)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(palette.edge).frame(width: 1, height: 14)
            ThroughputInline(presentation: throughput.presentation, narrow: narrowHeader)
                .frame(width: narrowHeader ? 37 : 52, alignment: .trailing)
        }
        .padding(.leading, narrowHeader ? 8 : 12)
        .padding(.trailing, showsPin ? 36 : (narrowHeader ? 8 : 12))
    }
    private var throughputAccessibility: String {
        let state = throughput.presentation
        let retained = state.sample != nil && (state.phase == .waiting || state.phase == .retained)
        return tr("tps.title") + " · " + (retained ? tr("tps.lastValue") + " " : "") + state.rateText + " t/s · " +
            tr("tps." + state.phase.rawValue) + (state.phase == .parallel ? " (\(state.sessions))" : "")
    }
    private var throughputDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("tps.title")).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(throughput.presentation.rateText + " t/s")
                    .font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Text(tr("tps.responseUpdates")).font(.system(size: 10)).foregroundStyle(palette.muted)
            Text(tr("tps." + throughput.presentation.phase.rawValue) +
                 (throughput.presentation.phase == .parallel ? " (\(throughput.presentation.sessions))" : ""))
                .font(.system(size: 10)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let date = throughput.presentation.sample?.recordedAt {
                Text(tr("tps.lastResponse", date.formatted(.dateTime.hour().minute().second().locale(text.locale))))
                    .font(.system(size: 10)).foregroundStyle(palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .help(tr("tps.method"))
    }
    private var compactDescription: String {
        guard store.status == .ready, !restricted, !store.demo else { return statusText }
        if model.consumptionDetected { return "· \(model.consumptionMessage)" }
        if creditBalance != nil { return "· \(tr("credits.remaining"))" }
        guard let selected else { return statusText }
        let countdown = QuotaText.countdown(selected.resetsAt, now: store.now, using: text, compact: true)
        return "· \(countdown)"
    }

    private var details: some View {
        VStack(spacing: DesignTokens.detailsSectionSpacing) {
            detailHeader
            ViewThatFits(in: .vertical) {
                detailContent.fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) {
                    detailContent.padding(.trailing, 8)
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(DesignTokens.detailsPadding)
        .foregroundStyle(palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(DetailContentHeight.self) { height in
            model.detailsSizeChanged?(height + DesignTokens.detailsHeaderHeight +
                DesignTokens.detailsSectionSpacing + 2 * DesignTokens.detailsPadding)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Text(store.demo ? tr("status.demo") : tr("status.remaining"))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // 原生拖动视图仅覆盖标题空白区，不得盖住 SwiftUI 操作按钮。
                .overlay(DragSurface(model: model).accessibilityHidden(true))
            HStack(spacing: 2) {
                Button { store.refresh(manual: true) } label: {
                    if store.refreshing {
                        ProgressView().controlSize(.mini).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                    }
                }
                .disabled(store.refreshing || store.demo)
                .focused($refreshFocused).keyboardShortcut("r", modifiers: [.command])
                .accessibilityLabel(store.refreshing ? tr("status.refreshing") : tr("refresh"))
                .help(tr("refresh"))
                if model.side != nil {
                    Button { model.togglePin?() } label: {
                        Image(systemName: model.pinned ? "pin.fill" : "pin").frame(width: 24, height: 24)
                    }
                    .foregroundStyle(model.pinned ? palette.signal : palette.muted)
                    .accessibilityLabel(model.pinned ? tr("pin.unpin") : tr("pin"))
                    .accessibilityValue(model.pinned ? tr("pin.on") : tr("pin.off"))
                    .help(model.pinned ? tr("pin.unpin.hint") : tr("pin.hint"))
                }
                Button { model.close?() } label: {
                    Image(systemName: "chevron.up").frame(width: 24, height: 24)
                }
                .accessibilityLabel(tr("details.collapse")).help(tr("details.collapse"))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.muted).buttonStyle(.borderless)
            .fixedSize(horizontal: true, vertical: true)
        }
        .frame(height: DesignTokens.detailsHeaderHeight)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.detailsSectionSpacing) {
            if model.throughputEnabled { throughputDetails }
            if let snapshot = store.state.snapshot, !snapshot.windows.isEmpty {
                if creditBalance != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("credits.remaining")).font(.system(size: 12, weight: .medium))
                        QuotaNumberText(text: detailCredits, value: creditBalance.map { NSDecimalNumber(decimal: $0).doubleValue },
                                        font: .system(size: 22, weight: .medium, design: .rounded), animate: store.status == .ready && !reduceMotion)
                            .id(numberScope + ":precision:\(creditDisplay.expandedDecimalPlaces)")
                            .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                            .help(fullCredits)
                        Text(tr("credits.trackHint")).font(.system(size: 10)).foregroundStyle(palette.muted)
                        QuotaProgressTrack(remaining: 100, color: tint, track: palette.track, surface: palette.surface,
                            animating: model.consumptionAnimating, speed: speedTier, reduceMotion: reduceMotion)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(statusText) · \(tr("credits.remaining")) · \(fullCredits)")
                }
                VStack(spacing: DesignTokens.detailsRowSpacing) {
                    ForEach(snapshot.windows) { window in quotaRow(window) }
                }
                if let error = store.state.error {
                    Text(error.message(using: text))
                        .font(.system(size: 11)).foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detailFooter
            } else {
                Text(emptyWindowMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(store.state.error == nil ? palette.muted : palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: DetailContentHeight.self, value: geometry.size.height)
            }
        }
    }

    private func quotaRow(_ window: QuotaWindow) -> some View {
        let color = windowTint(window)
        let countdown = QuotaText.countdown(window.resetsAt, now: store.now, using: text, compact: true)
        let exactReset = window.resetsAt.map { tr("quota.resetAt", text.date($0)) } ?? tr("quota.resetUnknown")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(window.detailName(using: text))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.ink)
                        .lineLimit(1).truncationMode(.tail).help(window.localizedName(using: text))
                    Text(countdown).font(.system(size: 10)).foregroundStyle(palette.muted)
                        .lineLimit(1).help(exactReset)
                }
                Spacer(minLength: 0)
                QuotaNumberText(text: QuotaText.percentage(window.remainingPercent, using: text), value: window.remainingPercent,
                                font: .system(size: 28, weight: .medium, design: .rounded), animate: store.status == .ready && !reduceMotion)
                    .id((store.state.snapshot?.accountKey ?? "unknown") + ":" + window.id).monospacedDigit()
                    .foregroundStyle(palette.ink).fixedSize()
            }
            QuotaProgressTrack(remaining: window.remainingPercent, color: color, track: palette.track, surface: palette.surface,
                animating: creditBalance == nil && model.consumptionAnimating && window.id == selected?.id,
                speed: speedTier, reduceMotion: reduceMotion)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("quota.summary", statusText, window.localizedName(using: text),
                              QuotaText.percentage(window.remainingPercent, using: text), countdown) + "，" + exactReset)
    }

    private func windowTint(_ window: QuotaWindow) -> Color {
        guard store.status == .ready, !restricted, let value = window.remainingPercent else { return palette.muted }
        return value <= 10 ? palette.danger : value <= 20 ? palette.warning : palette.signal
    }

    private var detailFooter: some View {
        HStack(spacing: 8) {
            if restricted || store.status == .stale || (store.status != .ready && store.state.error == nil) {
                Label(statusText, systemImage: "exclamationmark.circle")
                    .foregroundStyle(palette.warning)
            } else if store.state.error != nil, let date = store.state.snapshot?.fetchedAt {
                Text(tr("details.cached", date.formatted(.dateTime.hour().minute().locale(text.locale))))
                    .foregroundStyle(palette.muted)
            } else if model.consumptionDetected {
                Label(model.consumptionMessage, systemImage: "sparkles")
                    .foregroundStyle(palette.signal)
            } else if let date = store.state.snapshot?.fetchedAt {
                Text(tr("quota.updated", date.formatted(.dateTime.hour().minute().locale(text.locale))))
                    .foregroundStyle(palette.muted)
            }
            Spacer(minLength: 0)
            if let count = store.state.snapshot?.availableResetCount, count > 0 {
                Text(tr("details.resetCount", count)).foregroundStyle(palette.muted)
            }
        }
        .font(.system(size: 10)).lineLimit(1)
        .padding(.top, 2)
        .help(store.state.snapshot.map { tr("quota.updated", text.date($0.fetchedAt)) } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(store.state.snapshot.map { tr("quota.updated", text.date($0.fetchedAt)) } ?? "")
    }

}

private struct DetailContentHeight: PreferenceKey {
    static let defaultValue = 0.0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
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

struct ThroughputInline: View {
    let presentation: ThroughputPresentation
    let narrow: Bool
    var stacked = false
    @ObservedObject private var appearance = AppearanceStore.shared
    @ObservedObject private var language = LanguageStore.shared
    private var label: String {
        switch presentation.phase {
        case .measured: return presentation.rateText
        case .retained: return "~" + presentation.rateText
        case .waiting: return tr("tps.short.waiting")
        case .sampling: return "···"
        case .parallel: return tr("tps.short.parallel")
        case .idle: return tr("tps.short.idle")
        default: return "—"
        }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(label).font(.system(size: stacked ? DesignTokens.stackedSpeedFontSize : (narrow ? 12 : 14), weight: .medium, design: .rounded))
                .monospacedDigit()
            if presentation.phase == .measured || presentation.phase == .retained {
                Text("t/s").font(.system(size: 8))
            }
        }
        .foregroundStyle(presentation.phase == .measured ? appearance.palette.signal : appearance.palette.muted)
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityIdentifier("throughput.readout")
    }
}
