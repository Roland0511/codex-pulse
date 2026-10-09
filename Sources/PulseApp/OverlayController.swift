import AppKit
import Combine
import PulseCore
import SwiftUI

@MainActor final class PulsePanel: NSPanel {
    var keyboardEnabled = false
    override var canBecomeKey: Bool { keyboardEnabled }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { (delegate as? OverlayController)?.close() }
}

@MainActor final class OverlayController: NSObject, NSWindowDelegate {
    let model: OverlayModel
    let store: QuotaStore
    let panel: PulsePanel
    private var bodyFrame = CGRect.zero
    private var screen: NSScreen?
    private var animation: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var consumptionTask: Task<Void, Never>?
    private var confirmedUntil: ContinuousClock.Instant?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    private var startPoint: NSPoint?
    private var startFrame = CGRect.zero
    private var moved = false
    private(set) var visible = true

    init(store: QuotaStore, model: OverlayModel = OverlayModel()) {
        self.store = store; self.model = model
        panel = PulsePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Codex Pulse"
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: OverlayView(store: store, model: model))
        model.toggle = { [weak self] in self?.toggleDetails() }
        model.close = { [weak self] in self?.close() }
        model.togglePin = { [weak self] in self?.togglePin() }
        model.hover = { [weak self] entered in self?.hover(entered) }
        model.dragBegan = { [weak self] point in self?.beginDrag(point) }
        model.dragMoved = { [weak self] point in self?.drag(point) }
        model.dragEnded = { [weak self] in self?.endDrag() }
        restore()
        store.$recoverySerial.dropFirst().sink { [weak self] _ in self?.flash() }.store(in: &subscriptions)
        store.$consumptionSerial.dropFirst().sink { [weak self] _ in self?.showConsumption() }.store(in: &subscriptions)
        store.$working.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            self.model.working = value; self.updateConsumption()
        }.store(in: &subscriptions)
        store.$suspended.combineLatest(store.$now).dropFirst().sink { [weak self] _ in
            // 暂停与缓存过期在事件边界检查，无需为整个胶囊保留帧级轮询。
            Task { @MainActor [weak self] in self?.updateConsumption() }
        }.store(in: &subscriptions)
        store.$state.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            // Published 在赋值前发送；下一轮检查才能读到新状态。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateConsumption()
                if self.model.expanded { self.resize(animated: true) }
            }
        }.store(in: &subscriptions)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.model.expanded { self.close(); return nil }
            if event.type != .keyDown, event.window !== self.panel { self.close() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    private func screenID(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), let string = CFUUIDCreateString(nil, uuid) { return string as String }
        return String(id)
    }
    private var visibleFrame: CGRect { screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700) }
    private func restore() {
        let data = LocalDefaults.store.data(forKey: "overlayPosition")
        let saved = data.flatMap { try? JSONDecoder().decode(OverlayPosition.self, from: $0) }
        screen = saved.flatMap { saved in NSScreen.screens.first(where: { screenID($0) == saved.screenID }) } ?? NSScreen.main ?? NSScreen.screens.first
        let position = saved ?? OverlayPosition(screenID: screen.map(screenID) ?? "0", x: 0.85, y: 0.8, side: nil)
        model.side = position.side; model.blend = position.side == nil ? 0 : 1
        model.pinned = LocalDefaults.store.bool(forKey: "dockedPinned")
        model.width = targetSize().width
        bodyFrame = position.frame(in: visibleFrame, size: CGSize(width: model.width, height: model.height))
        applyFrame(bodyFrame)
    }
    private func save() {
        guard let screen else { return }
        let position = OverlayPosition.capture(frame: bodyFrame, visible: screen.visibleFrame, screenID: screenID(screen), side: model.side)
        if let data = try? JSONEncoder().encode(position) { LocalDefaults.store.set(data, forKey: "overlayPosition") }
    }

    func show(keyboard: Bool = false) {
        visible = true; store.hidden = false
        panel.orderFrontRegardless()
        recordInteraction("show", point: .zero)
        updateConsumption()
        if keyboard { open(keyboard: true) }
    }
    func hide() { close(); stopConsumption(); visible = false; store.hidden = true; panel.orderOut(nil) }
    func toggleVisible() { if visible { hide() } else { show() } }
    func toggleDetails() { if model.expanded { close() } else { open() } }
    func open(keyboard: Bool = false) {
        leaveTask?.cancel(); model.expanded = true; model.keyboardOpened = keyboard
        panel.keyboardEnabled = keyboard
        resize(animated: true); store.opened()
        if keyboard {
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView)
        }
    }
    func close() {
        guard model.expanded else { return }
        model.expanded = false; model.keyboardOpened = false; panel.keyboardEnabled = false
        if panel.isKeyWindow { panel.resignKey() }
        resize(animated: true)
    }
    func togglePin() {
        guard model.side != nil else { return }
        model.pinned.toggle()
        LocalDefaults.store.set(model.pinned, forKey: "dockedPinned")
        leaveTask?.cancel()
        // 取消固定后重新按离开延时收回；固定只影响长条，不固定详情。
        if !model.pinned { hover(false) }
        resize(animated: true)
    }
    func place(_ side: DockSide?) {
        model.side = side; model.blend = side == nil ? 0 : 1
        model.expanded = false; model.hovered = false
        if side == nil { bodyFrame.origin.x = visibleFrame.midX - DesignTokens.capsuleWidth / 2 }
        resize(animated: true); save()
    }
    private func hover(_ entered: Bool) {
        leaveTask?.cancel()
        guard startPoint == nil else { return }
        if entered { model.hovered = true; resize(animated: true) }
        else {
            leaveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(DesignTokens.hoverLeaveSeconds)) } catch { return }
                guard let self, self.startPoint == nil else { return }
                self.model.hovered = false; self.resize(animated: true)
            }
        }
    }
    private func beginDrag(_ point: NSPoint) {
        recordInteraction("drag-began", point: point)
        leaveTask?.cancel(); animation?.cancel()
        startPoint = point; startFrame = bodyFrame; moved = false
    }
    private func drag(_ point: NSPoint) {
        recordInteraction("drag-moved", point: point)
        guard let startPoint else { return }
        let dx = point.x - startPoint.x, dy = point.y - startPoint.y
        if !moved && hypot(dx, dy) < DesignTokens.dragThreshold { return }
        moved = true; model.expanded = false; model.keyboardOpened = false; panel.keyboardEnabled = false
        // 从标签拖动时以当前指针抓取比例转换到自由胶囊，避免跳到指针另一侧。
        let grab = min(1, max(0, (startPoint.x - startFrame.minX) / max(1, startFrame.width)))
        let intended = CGRect(x: startFrame.minX + dx - (DesignTokens.capsuleWidth - startFrame.width) * grab,
                              y: startFrame.minY + dy + startFrame.height - DesignTokens.height,
                              width: DesignTokens.capsuleWidth, height: DesignTokens.height)
        screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? screen
        let visible = visibleFrame
        let attachment = Attachment.calculate(intended: intended, visible: visible, travel: DesignTokens.attachmentTravel)
        model.side = attachment.side; model.blend = attachment.progress
        var frame = intended
        if model.side == .left { frame.origin.x = visible.minX }
        else if model.side == .right { frame.origin.x = visible.maxX - frame.width }
        else { frame.origin.x = min(visible.maxX - frame.width, max(visible.minX, frame.minX)) }
        frame.origin.y = min(visible.maxY - frame.height, max(visible.minY, frame.minY))
        model.width = frame.width; model.height = frame.height; applyFrame(frame)
    }
    private func endDrag() {
        recordInteraction(moved ? "drag-ended" : "click-ended", point: NSEvent.mouseLocation)
        guard startPoint != nil else { return }
        startPoint = nil
        if moved {
            model.hovered = false
            model.blend = model.side == nil ? 0 : 1
            resize(animated: true); save()
        } else { toggleDetails() }
        moved = false
    }
    private func targetSize() -> CGSize {
        if model.expanded {
            let windows = store.state.snapshot?.windows.count ?? 0
            let errors = store.state.error != nil || store.state.snapshot?.hasReachedLimit == true || store.state.snapshot?.ordinaryUsageAllowed == false
            return CGSize(width: DesignTokens.detailsWidth, height: min(visibleFrame.height - 32, max(188, 142 + Double(max(1, windows)) * 48 + (errors ? 30 : 0))))
        }
        return CGSize(width: model.compactWidth, height: DesignTokens.height)
    }
    private func resize(animated: Bool) {
        animation?.cancel()
        let size = targetSize(), original = bodyFrame, visible = visibleFrame
        let right = model.side == .right, left = model.side == .left
        var target = CGRect(origin: original.origin, size: size)
        if left { target.origin.x = visible.minX }
        else if right { target.origin.x = visible.maxX - size.width }
        else { target.origin.x = min(visible.maxX - size.width, max(visible.minX, target.minX)) }
        target.origin.y = min(visible.maxY - size.height, max(visible.minY, original.maxY - size.height))
        guard animated, !model.reduceMotion, original != target else {
            model.width = size.width; model.height = size.height; applyFrame(target); return
        }
        animation = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let progress = min(1, seconds / DesignTokens.expandSeconds)
                let eased = Self.ease(progress)
                let width = original.width + (target.width - original.width) * eased
                let height = original.height + (target.height - original.height) * eased
                // 每帧固定贴边锚点；右边不能把 x 与 width 分别插值。
                let x = left ? visible.minX : right ? visible.maxX - width : original.minX + (target.minX - original.minX) * eased
                let y = original.minY + (target.minY - original.minY) * eased
                self.model.width = width; self.model.height = height
                self.applyFrame(CGRect(x: x, y: y, width: width, height: height))
                if progress == 1 { self.save(); return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    private static func ease(_ x: Double) -> Double {
        let c = DesignTokens.expandCurve
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1-t) * (1-t) * t * a + 3 * (1-t) * t * t * b + t * t * t }
        var low = 0.0, high = 1.0
        for _ in 0..<12 { let mid = (low + high) / 2; if cubic(mid, c[0], c[2]) < x { low = mid } else { high = mid } }
        return cubic((low + high) / 2, c[1], c[3])
    }
    private func applyFrame(_ frame: CGRect) {
        bodyFrame = frame; panel.setFrame(frame.insetBy(dx: -16, dy: -16), display: true)
    }
    private func recordInteraction(_ kind: String, point: NSPoint) {
        guard let path = ProcessInfo.processInfo.environment["PULSE_INTERACTION_FILE"] else { return }
        let event: [String: Any] = ["kind": kind, "time": Date().timeIntervalSince1970,
            "point": [point.x, point.y], "frame": [bodyFrame.minX, bodyFrame.minY, bodyFrame.width, bodyFrame.height],
            "screen": [visibleFrame.minX, visibleFrame.minY, visibleFrame.width, visibleFrame.height],
            "keyWindow": panel.isKeyWindow, "onActiveSpace": panel.isOnActiveSpace, "visible": panel.isVisible,
            "reduceMotion": model.reduceMotion, "working": model.working, "flowAnimating": model.consumptionAnimating,
            "frontApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
        }
    }
    private func flash() {
        flashTask?.cancel(); guard !model.reduceMotion else { model.flash = 0; return }
        flashTask = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let progress = min(1, seconds / DesignTokens.recoverySeconds)
                self.model.flash = progress <= DesignTokens.peakHoldFraction ? 1 : (1-progress) / (1-DesignTokens.peakHoldFraction)
                if progress == 1 { return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    private func showConsumption() {
        confirmedUntil = ContinuousClock.now.advanced(by: .seconds(DesignTokens.consumptionSeconds))
        updateConsumption()
    }
    private func updateConsumption() {
        let confirmed = confirmedUntil.map { ContinuousClock.now < $0 } ?? false
        guard visible, !store.suspended, store.status == .ready, model.working || confirmed else { stopConsumption(); return }
        model.consumptionDetected = true
        model.consumptionAnimating = !model.reduceMotion
        // 连续流光的时钟由线条子视图持有，避免每帧发布整个胶囊模型。
        // 控制器只为有限额度下降反馈安排一次到期检查。
        guard !model.working, let deadline = confirmedUntil, confirmed else {
            consumptionTask?.cancel(); consumptionTask = nil; return
        }
        consumptionTask?.cancel()
        consumptionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.consumptionTask = nil; self.updateConsumption()
        }
    }
    private func stopConsumption() {
        consumptionTask?.cancel(); consumptionTask = nil
        model.consumptionAnimating = false; model.consumptionDetected = false
    }
    @objc private func screensChanged() {
        let currentID = screen.map(screenID)
        screen = NSScreen.screens.first(where: { screenID($0) == currentID }) ?? NSScreen.main ?? NSScreen.screens.first
        // 拔屏先直接移回有效屏幕，禁止离屏位置动画。
        resize(animated: false); save()
    }
    @objc private func accessibilityChanged() {
        if model.reduceMotion { animation?.cancel(); flashTask?.cancel(); model.flash = 0; model.consumptionAnimating = false; resize(animated: false) }
        updateConsumption()
        recordInteraction("accessibility-changed", point: .zero)
    }
    @objc private func spaceChanged() { recordInteraction("space-changed", point: .zero) }
    func windowDidResignKey(_ notification: Notification) { if model.keyboardOpened { close() } }
    func stop() {
        animation?.cancel(); leaveTask?.cancel(); flashTask?.cancel(); stopConsumption(); save()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel.orderOut(nil)
    }
}
