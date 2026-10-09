import AppKit
import Combine
import PulseCore
import UserNotifications

@MainActor final class QuotaStore: ObservableObject {
    @Published private(set) var state = QuotaState()
    @Published private(set) var refreshing = false
    @Published private(set) var now = Date()
    @Published private(set) var recoverySerial = 0
    @Published private(set) var consumptionSerial = 0
    @Published private(set) var working = false
    @Published private var reminderMessageKey: String?
    var reminderMessage: String? { reminderMessageKey.map { tr($0) } }
    let client: QuotaClient
    let activity: ActivityStore
    private var activitySubscription: AnyCancellable?
    let demo: Bool
    let demoScenario: String
    private var policy = RefreshPolicy()
    private var alerts: AlertPolicy
    private var observedIdentity: String?
    private var diagnosticTransitions: [[String: Any]] = []
    private var request: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?
    private var resetTimer: Task<Void, Never>?
    private var idleServer: Task<Void, Never>?
    private var clockTimer: Timer?
    private var demoTimer: Timer?
    private var confirmedBoundaries: Set<String> = []
    private var epoch = 0
    @Published private(set) var suspended = false
    var hidden = false {
        didSet {
            guard hidden != oldValue else { return }
            policy.visibilityChanged(hidden: hidden, lastSuccess: state.snapshot?.fetchedAt)
            schedule()
        }
    }
    var status: DataStatus { state.status(now: now) }
    @Published private(set) var remindersEnabled = false

    init(client: QuotaClient, demo: Bool = false, demoScenario: String = "normal", activity: ActivityStore? = nil) {
        self.client = client; self.demo = demo; self.demoScenario = demoScenario
        self.activity = activity ?? ActivityStore()
        if let data = LocalDefaults.store.data(forKey: "alertLedger"),
           let decoded = try? JSONDecoder().decode(AlertPolicy.self, from: data) { alerts = decoded }
        else { alerts = AlertPolicy() }
        if ProcessInfo.processInfo.environment["PULSE_DIAGNOSTICS_FILE"] != nil, !demo {
            self.activity.onDiagnosticSignal = { [weak self] in self?.recordDiagnosticSignal() }
        }
        if !demo {
            activitySubscription = self.activity.$isWorking.removeDuplicates().sink { [weak self] value in
                self?.working = value
                self?.writeDiagnostics()
            }
        }
        client.onIdentity = { [weak self] key in
            guard let self else { return }
            if key == nil || (self.observedIdentity != nil && self.observedIdentity != key) {
                self.state.identify(nil); self.confirmedBoundaries = []
            }
            self.observedIdentity = key
        }
        client.onAccountChanged = { [weak self] in
            // 延后至本行通知分发完毕，避免清空接收缓冲区时继续迭代。
            Task { @MainActor in self?.accountChanged() }
        }
        client.onQuotaUpdated = { [weak self] in
            guard let self, self.now.timeIntervalSince(self.state.snapshot?.fetchedAt ?? .distantPast) > 15 else { return }
            self.refresh()
        }
    }

    func start() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        clockTimer?.tolerance = 5
        if demo {
            let date = Date()
            var windows = [QuotaWindow(bucketID: "demo", slot: "primary", usedPercent: demoScenario == "low" ? 93 : 3, durationMinutes: 10080,
                                       resetsAt: date.addingTimeInterval(6 * 86400))]
            if demoScenario == "long" {
                windows = (0..<8).map { index in
                    QuotaWindow(bucketID: "demo-\(index)", bucketName: tr("demo.longBucket", index + 1),
                                slot: "primary", usedPercent: Double(index * 9), durationMinutes: (index + 1) * 120,
                                resetsAt: date.addingTimeInterval(Double(index + 1) * 90000))
                }
            }
            if demoScenario == "empty" { windows = [] }
            if demoScenario == "unknown" {
                windows = [QuotaWindow(bucketID: "demo", slot: "primary", usedPercent: nil, durationMinutes: nil, resetsAt: nil)]
            }
            if demoScenario != "loading" {
                state.accept(QuotaSnapshot(accountKey: "demo", windows: windows, availableResetCount: demoScenario == "unknown" ? nil : 2,
                                           fetchedAt: demoScenario == "stale" ? date.addingTimeInterval(-240) : date))
            }
            if demoScenario == "error" || demoScenario == "stale" { state.fail(.disconnected) }
            if demoScenario == "logout" { state.fail(.unauthenticated) }
            if demoScenario == "consuming" {
                // 明确隔离的合成演示：每 6 秒播放一次，正常模式不会启用此计时器。
                consumptionSerial += 1
                demoTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.consumptionSerial += 1 }
                }
            }
            if demoScenario == "working" { working = true }
        } else { activity.start(); refresh() }
    }

    func refresh(manual: Bool = false) {
        guard !demo, request == nil, !suspended else { return }
        idleServer?.cancel()
        scheduler?.cancel(); scheduler = nil
        refreshing = true
        let currentEpoch = epoch
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let next = try await self.client.read()
                guard currentEpoch == self.epoch, !Task.isCancelled else { return }
                let previous = self.state.snapshot
                self.state.accept(next); self.now = Date()
                if ConsumptionPolicy.detected(previous: previous, next: next) { self.consumptionSerial += 1 }
                if let previous, previous.accountKey == next.accountKey,
                   next.ordinaryUsageAllowed != false, !next.hasReachedLimit,
                   next.windows.contains(where: { window in
                       guard let old = previous.windows.first(where: { $0.id == window.id }),
                             let used = window.usedPercent, let oldUsed = old.usedPercent else { return false }
                       return AlertPolicy.isNewCycle(priorReset: old.resetsAt, reset: window.resetsAt,
                                                     priorUsed: oldUsed, used: used, now: next.fetchedAt)
                   }) { self.recoverySerial += 1 }
                if self.remindersEnabled { self.deliverAlerts(self.alerts.evaluate(next)) }
                if let ledger = try? JSONEncoder().encode(self.alerts) { LocalDefaults.store.set(ledger, forKey: "alertLedger") }
                self.policy.completed(success: true, now: self.now, hidden: self.hidden)
                self.scheduleReset(next)
            } catch {
                guard currentEpoch == self.epoch else { return }
                self.now = Date()
                self.state.fail(error as? QuotaError ?? .serviceUnavailable)
                self.policy.completed(success: false, now: self.now, hidden: self.hidden)
            }
            guard currentEpoch == self.epoch else { return }
            self.refreshing = false; self.request = nil; self.schedule()
            self.writeDiagnostics()
            // 轮询是数据保证；仅保留 10 秒通知观察期，避免让重型服务空转一分钟。
            self.idleServer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.request == nil else { return }
                while self.client.isBusy {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                self.client.stop(); self.writeDiagnostics()
            }
        }
        writeDiagnostics()
    }

    func inspectHookTrust(commands: Set<String>) async throws -> HookTrustSummary {
        guard !demo, !suspended else { throw QuotaError.serviceUnavailable }
        idleServer?.cancel()
        defer {
            idleServer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                while self.client.isBusy || self.request != nil {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                self.client.stop(); self.writeDiagnostics()
            }
        }
        return try await client.readHookTrust(commands: commands, cwd: FileManager.default.homeDirectoryForCurrentUser)
    }

    func opened() {
        now = Date()
        if now.timeIntervalSince(state.snapshot?.fetchedAt ?? .distantPast) > 15 { refresh() }
    }

    private func schedule() {
        scheduler?.cancel()
        guard !suspended, !demo, request == nil else { return }
        let delay = max(1, policy.nextAttempt.timeIntervalSinceNow)
        scheduler = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.policy.shouldRefresh(now: Date(), suspended: self.suspended) else { return }
            self.refresh()
        }
    }

    private func scheduleReset(_ snapshot: QuotaSnapshot) {
        resetTimer?.cancel()
        let boundaries = snapshot.windows.compactMap { window -> (String, Date)? in
            guard let date = window.resetsAt else { return nil }
            return ("\(snapshot.accountKey):\(window.id):\(date.timeIntervalSince1970)", date)
        }
        let keys = Set(boundaries.map { $0.0 })
        confirmedBoundaries = confirmedBoundaries.intersection(keys)
        guard let boundary = boundaries.filter({ !confirmedBoundaries.contains($0.0) }).min(by: { $0.1 < $1.1 }) else { return }
        resetTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, boundary.1.timeIntervalSinceNow))) } catch { return }
            guard let self, !self.suspended else { return }
            self.confirmedBoundaries.insert(boundary.0)
            self.now = Date(); self.refresh()
        }
    }

    func suspend() {
        suspended = true; epoch += 1
        activity.suspend()
        scheduler?.cancel(); resetTimer?.cancel(); idleServer?.cancel(); request?.cancel(); request = nil
        client.stop(); refreshing = false; now = Date()
        writeDiagnostics()
    }
    func resume() { suspended = false; activity.resume(); now = Date(); policy.resume(); refresh() }
    func timeChanged() { now = Date(); resetTimer?.cancel(); policy.resume(); refresh() }
    private func accountChanged() {
        // 新版服务初始化也通知 account/updated。读取已在前后核对账户；
        // 先清掉旧显示，交由当前读取完成核对，避免每次握手都重启服务。
        state.identify(nil); observedIdentity = nil; confirmedBoundaries = []
        resetTimer?.cancel()
        if request != nil { return }
        epoch += 1; request?.cancel(); request = nil; refreshing = false
        client.stop(); policy.resume(); refresh()
    }
    func stop() {
        suspend(); clockTimer?.invalidate(); clockTimer = nil; demoTimer?.invalidate(); demoTimer = nil
        activity.stop()
        writeDiagnostics()
    }

    func restoreReminders(_ enabled: Bool) { remindersEnabled = enabled }

    func enableReminders(_ enabled: Bool) {
        guard !demo else { reminderMessageKey = "reminders.demo"; return }
        if !enabled { remindersEnabled = false; LocalDefaults.store.set(false, forKey: "remindersEnabled"); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.remindersEnabled = granted
                LocalDefaults.store.set(granted, forKey: "remindersEnabled")
                if granted { self?.refresh(manual: true) }
                self?.reminderMessageKey = granted ? nil : "reminders.denied"
            }
        }
    }
    private func deliverAlerts(_ items: [QuotaAlert]) {
        guard remindersEnabled else { return }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = tr("reminders.title")
            let text = LanguageStore.shared.text
            content.body = tr("reminders.body", item.window.localizedName(using: text),
                              QuotaText.percentage(item.window.remainingPercent, using: text))
            content.sound = .default
            let notification = UNNotificationRequest(identifier: QuotaClient.digest(item.key), content: content, trigger: nil)
            UNUserNotificationCenter.current().add(notification) { _ in }
        }
    }
    private func recordDiagnosticSignal() {
        diagnosticTransitions.append(["time": Date().timeIntervalSince1970,
            "event": activity.lastReceivedEvent?.rawValue as Any? ?? NSNull(),
            "working": working, "suspended": suspended,
            "counts": activity.diagnosticCounts, "relationsBefore": activity.diagnosticRelations])
        if diagnosticTransitions.count > 64 { diagnosticTransitions.removeFirst(diagnosticTransitions.count - 64) }
        writeDiagnostics()
    }
    private func writeDiagnostics() {
        guard let path = ProcessInfo.processInfo.environment["PULSE_DIAGNOSTICS_FILE"], !demo else { return }
        // 仅按显式本地路径输出进程/请求计数，不包含身份、额度或原始响应。
        let payload: [String: Any] = ["sampledAt": ISO8601DateFormatter().string(from: Date()),
            "appPID": ProcessInfo.processInfo.processIdentifier, "serverPID": client.processID as Any? ?? NSNull(),
            "requestCount": client.requestCount, "quotaReadCount": client.quotaReadCount,
            "refreshing": refreshing, "suspended": suspended, "working": working,
            "activityHasReceivedEvent": activity.hasReceivedEvent,
            "lastActivityEvent": activity.lastReceivedEvent?.rawValue as Any? ?? NSNull(),
            "activityCounts": activity.diagnosticCounts, "activityTransitions": diagnosticTransitions]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
