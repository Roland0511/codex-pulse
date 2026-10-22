import Foundation

/// Only protocol counters, identities and clocks survive projection; never message bodies.
public struct ThroughputEvent: Sendable {
    public let fields: [String: String]
    public static func read(_ data: Data) throws -> Self {
        Self(fields: try JSONMetadataProjection.read(data, paths: [
            "type", "timestamp", "payload.type", "payload.thread_id", "payload.turn_id", "payload.response_id",
            "payload.item.id", "payload.item.type", "payload.started_at_ms", "payload.completed_at_ms",
            "payload.usage.output_tokens", "payload.usage.reasoning_output_tokens",
            "payload.info.total_token_usage.output_tokens"
        ]))
    }
}

public struct ThroughputSample: Equatable, Sendable {
    public let tokensPerSecond: Double
    public let recordedAt: Date
    public let turn: String
    public init(tokensPerSecond: Double, recordedAt: Date, turn: String) {
        self.tokensPerSecond = tokensPerSecond; self.recordedAt = recordedAt; self.turn = turn
    }
}

/// Inspired by codex-statusbar's official-output / model-item-interval-union approach.
/// Each response consumes only the timing windows since the preceding response boundary.
/// Missing boundaries or timing invalidate that sample, never guess zero or bridge tool waits.
public struct ThroughputTracker: Sendable {
    public private(set) var sample: ThroughputSample?
    private var turn: String?
    private var intervals: [(Int64, Int64)] = []
    private var items: Set<String> = []
    private var responses: Set<String> = []
    private var valid = false
    private var directCarrier = false
    private var legacyBaseline: Int64?
    private var legacyOutput: Int64?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func receive(_ event: ThroughputEvent, session: String) {
        let f = event.fields
        if let id = f["payload.thread_id"], ActivitySignal.hash(id) != session { return }
        let type = f["type"], kind = f["payload.type"]
        let stamp = f["timestamp"].flatMap(Self.date) ?? .distantPast
        // A file's ordering, rather than local arrival time, defines response boundaries.
        if type == "event_msg", kind == "task_started", let id = f["payload.turn_id"] {
            let next = ActivitySignal.hash(id)
            guard turn != next else { return }
            turn = next; intervals = []; items = []; responses = []
            valid = true; directCarrier = false; legacyBaseline = legacyOutput; sample = nil
            return
        }
        if type == "event_msg", kind == "token_count" {
            guard let total = Self.count(f["payload.info.total_token_usage.output_tokens"]) else { return }
            defer { legacyOutput = total }
            guard !directCarrier else { return }
            // Cumulative deltas deduplicate the legacy carrier. Never deduplicate by token values.
            guard let baseline = legacyBaseline, total >= baseline else {
                legacyBaseline = total; intervals = []; sample = nil; return
            }
            guard total > baseline else { return }
            publish(output: total - baseline, at: stamp)
            legacyBaseline = total
            return
        }
        if type == "event_msg", kind == "item_completed",
           ["Reasoning", "AgentMessage"].contains(f["payload.item.type"] ?? ""), f["payload.turn_id"] == nil {
            valid = false; intervals = []; sample = nil; return
        }
        guard let current = turn, let id = f["payload.turn_id"], ActivitySignal.hash(id) == current else { return }
        if type == "event_msg", kind == "item_completed" {
            guard ["Reasoning", "AgentMessage"].contains(f["payload.item.type"] ?? "") else { return }
            guard let id = f["payload.item.id"] else { valid = false; sample = nil; return }
            guard !items.contains(id) else { return }
            guard items.count < 2048 else { valid = false; sample = nil; return }
            items.insert(id)
            guard let start = Self.count(f["payload.started_at_ms"]),
                  let end = Self.count(f["payload.completed_at_ms"]), end > start, end - start <= 600_000,
                  abs(Double(end) / 1000 - stamp.timeIntervalSince1970) < 60 else {
                valid = false; sample = nil; return
            }
            intervals.append((start, end))
        } else if type == "token_usage_record" {
            guard let response = f["payload.response_id"], !response.isEmpty else { intervals = []; sample = nil; return }
            guard !responses.contains(response) else { return }
            guard responses.count < 2048 else { valid = false; sample = nil; return }
            responses.insert(response)
            // On a mixed-format file, only the direct carrier contributes. Clear any legacy sample.
            if !directCarrier { directCarrier = true; sample = nil }
            guard let output = Self.count(f["payload.usage.output_tokens"]),
                  Self.count(f["payload.usage.reasoning_output_tokens"]).map({ $0 <= output }) ?? true else {
                intervals = []; sample = nil; return
            }
            publish(output: output, at: stamp)
        } else if type == "event_msg", kind == "turn_aborted" {
            valid = false; intervals = []; sample = nil
        }
    }
    private mutating func publish(output: Int64, at date: Date) {
        defer { intervals = [] }
        guard valid, let turn, output > 0, !intervals.isEmpty else { sample = nil; return }
        var milliseconds: Int64 = 0, lastEnd: Int64 = 0
        for (start, end) in intervals.sorted(by: { $0.0 < $1.0 }) {
            milliseconds += max(0, end - max(start, lastEnd)); lastEnd = max(lastEnd, end)
        }
        let rate = Double(output) * 1000 / Double(milliseconds)
        guard Double(lastEnd) / 1000 <= date.timeIntervalSince1970 + 1, milliseconds >= 50, rate.isFinite, rate > 0, rate <= 100_000, date != .distantPast else {
            sample = nil; return
        }
        sample = ThroughputSample(tokensPerSecond: rate, recordedAt: date, turn: turn)
    }
    private static func count(_ string: String?) -> Int64? {
        guard let string, let number = Int64(string), number >= 0 else { return nil }; return number
    }
    private static func date(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

public enum ThroughputPhase: String, Equatable, Sendable {
    case disconnected, idle, waiting, sampling, measured, retained, unavailable, paused
}
public struct ThroughputPresentation: Equatable, Sendable {
    public let phase: ThroughputPhase
    public let sample: ThroughputSample?
    public let sessions: Int
    public let generatingSessions: Int
    public let contributingSessions: Int
    public var isAggregate: Bool { sessions > 1 }
    public var isPartial: Bool { sample != nil && contributingSessions < generatingSessions }
    public var showsApproximation: Bool { phase == .retained || isPartial }
    public init(phase: ThroughputPhase, sample: ThroughputSample? = nil, sessions: Int = 0,
                generatingSessions: Int = 0, contributingSessions: Int = 0) {
        self.phase = phase; self.sample = sample; self.sessions = sessions
        self.generatingSessions = generatingSessions; self.contributingSessions = contributingSessions
    }
    public static func resolve(connected: Bool, paused: Bool, turns: [String: String], waiting: Set<String>,
                               samples: [String: ThroughputSample], unavailable: Set<String>, now: Date) -> Self {
        if paused { return .init(phase: .paused) }
        guard connected else { return .init(phase: .disconnected) }
        guard !turns.isEmpty else { return .init(phase: .idle) }
        func validSample(_ session: String, _ turn: String) -> ThroughputSample? {
            guard !unavailable.contains(session), let sample = samples[session], sample.turn == turn,
                  sample.tokensPerSecond.isFinite, sample.tokensPerSecond > 0, sample.tokensPerSecond <= 100_000,
                  now.timeIntervalSince(sample.recordedAt) >= -5,
                  now.timeIntervalSince(sample.recordedAt) <= 60 else { return nil }
            return sample
        }
        if turns.count == 1, let (session, turn) = turns.first, waiting.contains(session) {
            return .init(phase: .waiting, sample: validSample(session, turn), sessions: 1)
        }
        let generating = turns.filter { !waiting.contains($0.key) }
        let contributions = generating.sorted { $0.key < $1.key }.compactMap { validSample($0.key, $0.value) }
        guard let oldest = contributions.map(\.recordedAt).min() else {
            let phase: ThroughputPhase = generating.isEmpty ? .waiting :
                (generating.keys.allSatisfy { unavailable.contains($0) } ? .unavailable : .sampling)
            return .init(phase: phase, sessions: turns.count, generatingSessions: generating.count)
        }
        // Display-only sum of latest per-response rates. The oldest contributor controls freshness;
        // the empty aggregate turn is never fed back to a session tracker or persisted.
        let total = ThroughputSample(tokensPerSecond: contributions.reduce(0) { $0 + $1.tokensPerSecond },
                                     recordedAt: oldest, turn: turns.count == 1 ? contributions[0].turn : "")
        return .init(phase: now.timeIntervalSince(oldest) <= 3 ? .measured : .retained, sample: total,
                     sessions: turns.count, generatingSessions: generating.count, contributingSessions: contributions.count)
    }
    public var rateText: String {
        guard let rate = sample?.tokensPerSecond, rate.isFinite, rate > 0 else { return "—" }
        if rate < 1 { return "<1" }
        if rate >= 10_000 { return String(Int(rate / 1000)) + "k" }
        if rate >= 1000 { return String(format: "%.1fk", locale: Locale(identifier: "en_US_POSIX"), rate / 1000) }
        return String(Int(rate.rounded(.down)))
    }
}
