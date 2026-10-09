import Combine
import Darwin
import Foundation
import PulseCore

@MainActor final class ActivityStore: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var hasReceivedEvent = false
    @Published private(set) var message: String?
    private(set) var lastReceivedEvent: ActivityEvent?
    private var ledger = ActivityLedger()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var timer: Timer?
    private var suspended = false
    private var verified = false
    private var buffered: [ActivitySignal] = []
    var onUnverifiedSignal: (() -> Void)?
    var onDiagnosticSignal: (() -> Void)?
    var diagnosticCounts: [String: Int] { ledger.diagnosticCounts }
    private(set) var diagnosticRelations: [String: Int] = [:]
    private let url: URL
    // 测试注入生命期判断；正式默认使用 PID + 启动时间，同一用户且仍存活。
    private let alive: (ActivityOwner) -> Bool
    init(url: URL = ActivitySocket.location, alive: @escaping (ActivityOwner) -> Bool = { $0.isAlive }) {
        self.url = url; self.alive = alive
    }
    func start() {
        guard descriptor < 0 else { return }
        do {
            descriptor = try ActivitySocket.listen(at: url)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
            self.source = source; source.resume(); message = nil
        } catch { message = "工作状态连接不可用，仍可读取额度。" }
    }
    private func drain() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2049)
        for _ in 0..<64 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            guard count <= 2048, let signal = try? JSONDecoder().decode(ActivitySignal.self, from: Data(buffer.prefix(count))) else { continue }
            receive(signal)
        }
    }
    func receive(_ signal: ActivitySignal) {
        guard signal.valid(now: Date()), alive(signal.owner) else { return }
        lastReceivedEvent = signal.event
        hasReceivedEvent = true
        if onDiagnosticSignal != nil { diagnosticRelations = ledger.diagnosticRelations(to: signal) }
        defer { onDiagnosticSignal?() }
        guard verified else {
            buffered.append(signal)
            if buffered.count > 32 { buffered.removeFirst(buffered.count - 32) }
            onUnverifiedSignal?(); return
        }
        ledger.receive(signal, now: Date()); publish()
    }
    func setVerified(_ value: Bool) {
        verified = value
        if value {
            let signals = buffered; buffered = []
            for signal in signals where signal.valid(now: Date()) && alive(signal.owner) { ledger.receive(signal, now: Date()) }
        } else { ledger.clear() }
        publish()
    }
    private func publish() {
        ledger.prune(now: Date(), alive: alive)
        let next = !suspended && ledger.isWorking
        if isWorking != next { isWorking = next }
        if ledger.hasLiveEntries, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
            timer?.tolerance = 0.2
        } else if !ledger.hasLiveEntries { timer?.invalidate(); timer = nil }
    }
    func suspend() { suspended = true; publish() }
    func resume() { suspended = false; publish() }
    func stop() {
        source?.cancel(); source = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1; unlink(url.path) }
        timer?.invalidate(); timer = nil; ledger.clear(); isWorking = false
        buffered = []; verified = false; lastReceivedEvent = nil
    }
}
