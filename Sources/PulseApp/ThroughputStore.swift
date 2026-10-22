import Combine
import Foundation
import PulseCore

enum ThroughputLayout: String, CaseIterable {
    case horizontal, stacked
}

@MainActor extension ThroughputPresentation {
    var readingTitle: String { tr(isAggregate ? "tps.total" : "tps.title") }
    var readingStatus: String {
        let status = tr("tps." + (isAggregate && (phase == .measured || phase == .retained) ? "total." : "") + phase.rawValue)
        guard isAggregate else { return status }
        let coverage = tr("tps.coverage", contributingSessions, generatingSessions, sessions - generatingSessions)
        return coverage + " · " + status + (isPartial ? " · " + tr("tps.partial") : "")
    }
    func readingTimestamp(_ time: String) -> String {
        tr(isAggregate ? "tps.oldestResponse" : "tps.lastResponse", time)
    }
}

@MainActor final class ThroughputStore: ObservableObject {
    @Published private(set) var layout: ThroughputLayout
    @Published private(set) var enabled: Bool
    @Published private(set) var presentation = ThroughputPresentation(phase: .disconnected)
    private let defaults: UserDefaults
    private let reader: ThroughputReader
    private var context = ActivityStore.Context()
    private var subscription: AnyCancellable?
    private var poll: Task<Void, Never>?
    private var paused = false
    private var hidden = false
    private var generation = 0
    init(defaults: UserDefaults? = nil, root: URL? = nil, enabled: Bool? = nil) {
        let storage = defaults ?? LocalDefaults.store
        self.defaults = storage
        layout = storage.string(forKey: "throughputLayout").flatMap(ThroughputLayout.init(rawValue:)) ?? .horizontal
        self.enabled = enabled ?? (storage.object(forKey: "throughputEnabled") as? Bool ?? true)
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        reader = ThroughputReader(root: root ?? home.appendingPathComponent("sessions", isDirectory: true))
    }
    func bind(_ activity: ActivityStore) {
        subscription = activity.$context.removeDuplicates().sink { [weak self] context in
            guard let self else { return }
            self.context = context; self.restart()
        }
    }
    func setLayout(_ value: ThroughputLayout) {
        guard value != layout else { return }
        layout = value; defaults.set(value.rawValue, forKey: "throughputLayout")
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; defaults.set(value, forKey: "throughputEnabled"); restart()
    }
    func setPaused(_ value: Bool) { guard paused != value else { return }; paused = value; restart() }
    func setHidden(_ value: Bool) { guard hidden != value else { return }; hidden = value; restart() }
    private func restart() {
        generation += 1; let epoch = generation
        poll?.cancel(); poll = nil
        presentation = ThroughputPresentation.resolve(connected: context.connected, paused: paused || hidden || !enabled,
            turns: context.turns, waiting: context.waiting, samples: [:], unavailable: [], now: Date())
        guard enabled, !paused, !hidden, context.connected, !context.turns.isEmpty else {
            let reader = reader
            Task { await reader.reset() }
            return
        }
        let context = context, reader = reader
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let result = await reader.read(sessions: Set(context.turns.keys))
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                let next = ThroughputPresentation.resolve(connected: context.connected, paused: false,
                    turns: context.turns, waiting: context.waiting, samples: result.samples,
                    unavailable: result.unavailable, now: Date())
                if self.presentation != next { self.presentation = next }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func stop() {
        generation += 1; poll?.cancel(); poll = nil; subscription?.cancel(); subscription = nil
        presentation = .init(phase: .disconnected)
        let reader = reader; Task { await reader.reset() }
    }
}
