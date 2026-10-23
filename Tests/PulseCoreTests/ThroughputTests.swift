import Foundation
import Darwin
import Testing
@testable import PulseCore

private let epoch: Int64 = 1_894_000_000_000
private let sessionID = "11111111-1111-4111-8111-111111111111"
private let sessionHash = ActivitySignal.hash(sessionID)
private func line(_ kind: String, _ values: [String: Any] = [:], type: String = "event_msg") throws -> Data {
    var payload: [String: Any] = ["type": kind, "turn_id": "turn", "thread_id": sessionID]
    payload.merge(values) { _, next in next }
    var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2030-01-07T07:07:10.000Z", "payload": payload], options: [.sortedKeys])
    data.append(10); return data
}
private func item(_ id: String, _ start: Int64, _ end: Int64, kind: String = "Reasoning") throws -> Data {
    try line("item_completed", ["item": ["id": id, "type": kind, "text": "PRIVATE BODY MUST BE SKIPPED"],
                                "started_at_ms": epoch + start, "completed_at_ms": epoch + end])
}
private func usage(_ id: String, _ tokens: Int64 = 100) throws -> Data {
    try line("", ["response_id": id, "usage": ["output_tokens": tokens, "reasoning_output_tokens": tokens / 2]], type: "token_usage_record")
}
private func receive(_ tracker: inout ThroughputTracker, _ data: Data) throws {
    tracker.receive(try ThroughputEvent.read(data), session: sessionHash)
}

@Suite("逐响应 TPS 元数据") struct ThroughputTests {
    @Test func projectionSkipsBodiesAndRejectsAmbiguousOrMalformedCounters() throws {
        let event = try ThroughputEvent.read(item("a", 0, 1000))
        #expect(!event.fields.values.contains(where: { $0.contains("PRIVATE") }))
        #expect(event.fields["payload.item.type"] == "Reasoning")
        #expect(throws: (any Error).self) { try ThroughputEvent.read(Data(#"{"type":"event_msg","type":"token_usage_record"}"#.utf8)) }
        #expect(throws: (any Error).self) { try ThroughputEvent.read(Data(#"{"type":"event_msg","payload": {"text":"\q"}}"#.utf8)) }
        var tracker = ThroughputTracker()
        try receive(&tracker, line("task_started")); try receive(&tracker, item("a", 0, 1000))
        try receive(&tracker, line("", ["response_id": "r", "usage": ["output_tokens": true]], type: "token_usage_record"))
        #expect(tracker.sample == nil)
    }
    @Test func unionExcludesToolsAndGapsAndDeduplicatesByIdentity() throws {
        var tracker = ThroughputTracker()
        try receive(&tracker, line("task_started"))
        try receive(&tracker, item("a", 0, 2000)); try receive(&tracker, item("b", 1000, 3000))
        try receive(&tracker, item("a", 0, 2000)) // duplicate item
        try receive(&tracker, item("tool", 3000, 9000, kind: "CommandExecution"))
        try receive(&tracker, item("c", 10000, 11000, kind: "AgentMessage"))
        try receive(&tracker, usage("r", 400))
        #expect(tracker.sample?.tokensPerSecond == 100) // 4s union, not 11s wall time
        try receive(&tracker, item("d", 12000, 14000))
        try receive(&tracker, usage("r", 400)) // duplicate cannot consume next windows
        try receive(&tracker, usage("r2", 400)) // identical token count, distinct response
        #expect(tracker.sample?.tokensPerSecond == 200)
        try receive(&tracker, line("token_count", ["info": ["total_token_usage": ["output_tokens": 800]]]))
        #expect(tracker.sample?.tokensPerSecond == 200) // legacy duplicate ignored
    }
    @Test func missingAnchorTimingOrForeignTurnNeverProducesAFalseRate() throws {
        var tracker = ThroughputTracker()
        try receive(&tracker, item("a", 0, 1000)); try receive(&tracker, usage("r")); #expect(tracker.sample == nil)
        try receive(&tracker, line("task_started"))
        try receive(&tracker, line("item_completed", ["item": ["id": "bad", "type": "AgentMessage"]]))
        try receive(&tracker, item("b", 0, 1000)); try receive(&tracker, usage("r2")); #expect(tracker.sample == nil)
        tracker.reset(); try receive(&tracker, line("task_started")); try receive(&tracker, item("c", 0, 1000))
        try receive(&tracker, line("", ["turn_id": "foreign", "response_id": "x", "usage": ["output_tokens": 500]], type: "token_usage_record"))
        #expect(tracker.sample == nil)
        try receive(&tracker, usage("r3")); #expect(tracker.sample?.tokensPerSecond == 100)
        try receive(&tracker, line("turn_aborted")); #expect(tracker.sample == nil)
    }
    @Test func legacyCumulativeDeltaHandlesRepeatedValuesAndReset() throws {
        func count(_ value: Int) throws -> Data { try line("token_count", ["info": ["total_token_usage": ["output_tokens": value]]]) }
        var tracker = ThroughputTracker()
        try receive(&tracker, count(1000)); try receive(&tracker, line("task_started"))
        try receive(&tracker, item("a", 0, 1000)); try receive(&tracker, count(1100))
        #expect(tracker.sample?.tokensPerSecond == 100)
        try receive(&tracker, item("b", 2000, 4000)); try receive(&tracker, count(1100)); try receive(&tracker, count(1200))
        #expect(tracker.sample?.tokensPerSecond == 50)
        try receive(&tracker, count(10)); #expect(tracker.sample?.tokensPerSecond == 50)
    }
    @Test func sampleStateRejectsOldTurnsStaleAndDisconnected() {
        let now = Date(), sample = ThroughputSample(tokensPerSecond: 82, recordedAt: now, turn: "t")
        func state(_ turns: [String: String] = ["s": "t"], connected: Bool = true, paused: Bool = false,
                   waiting: Set<String> = [], unavailable: Set<String> = [], date: Date? = nil) -> ThroughputPresentation {
            .resolve(connected: connected, paused: paused, turns: turns, waiting: waiting,
                     samples: ["s": sample], unavailable: unavailable, now: date ?? now)
        }
        #expect(state().phase == .measured)
        #expect(state(date: now.addingTimeInterval(4)).phase == .retained)
        #expect(state(date: now.addingTimeInterval(61)).phase == .retained)
        #expect(state(date: now.addingTimeInterval(3600)).sample == sample)
        #expect(state(["s": "next"]).phase == .sampling)
        #expect(state(["s": "t", "other": "u"]).sample?.tokensPerSecond == 82)
        #expect(state(["s": "t", "other": "u"]).isPartial)
        #expect(state(waiting: ["s"]).phase == .waiting)
        #expect(state(unavailable: ["s"]).sample == nil)
        #expect(state(connected: false).phase == .disconnected)
        #expect(state(paused: true).phase == .paused)
        #expect(state([:]).phase == .idle)
    }
    @Test func parallelTotalExcludesWaitingInvalidOldAndEndedSessions() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let a = ThroughputSample(tokensPerSecond: 82, recordedAt: now.addingTimeInterval(-4), turn: "a")
        let b = ThroughputSample(tokensPerSecond: 61, recordedAt: now, turn: "b")
        func state(turns: [String: String] = ["s1": "a", "s2": "b"], waiting: Set<String> = [],
                   samples: [String: ThroughputSample]? = nil, unavailable: Set<String> = [], date: Date? = nil) -> ThroughputPresentation {
            .resolve(connected: true, paused: false, turns: turns, waiting: waiting,
                     samples: samples ?? ["s1": a, "s2": b], unavailable: unavailable, now: date ?? now)
        }
        let total = state()
        #expect(total.sample?.tokensPerSecond == 143 && total.isAggregate && !total.isPartial)
        #expect(total.contributingSessions == 2 && total.generatingSessions == 2)
        #expect(total.phase == .retained && total.sample?.recordedAt == a.recordedAt)
        let waiting = state(waiting: ["s1"])
        #expect(waiting.sample?.tokensPerSecond == 61 && waiting.phase == .measured && !waiting.isPartial)
        #expect(waiting.generatingSessions == 1 && waiting.sessions == 2)
        #expect(state(waiting: ["s1", "s2"]).phase == .waiting)
        #expect(state(waiting: ["s1", "s2"]).sample == nil)
        #expect(state(turns: ["s2": "b"]).sample?.tokensPerSecond == 61)
        #expect(!state(turns: ["s2": "b"]).isAggregate)
        let stale = state(date: now.addingTimeInterval(57))
        #expect(stale.sample?.tokensPerSecond == 143 && !stale.isPartial && stale.showsApproximation)
        #expect(state(date: now.addingTimeInterval(61)).sample?.tokensPerSecond == 143)
        #expect(state(turns: ["s1": "next", "s2": "b"]).sample?.tokensPerSecond == 61)
        #expect(state(unavailable: ["s1"]).sample?.tokensPerSecond == 61)
        #expect(state(unavailable: ["s1", "s2"]).phase == .unavailable)
        #expect(state(samples: [:]).phase == .sampling)
        for invalid in [Double.nan, .infinity, -1, 0, 100_001] {
            let bad = ThroughputSample(tokensPerSecond: invalid, recordedAt: now, turn: "a")
            #expect(state(samples: ["s1": bad, "s2": b]).sample?.tokensPerSecond == 61)
        }
        let future = ThroughputSample(tokensPerSecond: 99, recordedAt: now.addingTimeInterval(6), turn: "a")
        #expect(state(samples: ["s1": future, "s2": b]).sample?.tokensPerSecond == 61)
        #expect(state(turns: [:]).sample == nil)
    }
    @Test func missingResponseIdentityCannotLeakWindowsIntoAnotherResponse() throws {
        var tracker = ThroughputTracker()
        try receive(&tracker, line("task_started")); try receive(&tracker, item("a", 0, 1000))
        try receive(&tracker, line("", ["usage": ["output_tokens": 500]], type: "token_usage_record"))
        #expect(tracker.sample == nil)
        try receive(&tracker, item("b", 5000, 6000)); try receive(&tracker, usage("valid", 100))
        #expect(tracker.sample?.tokensPerSecond == 100)
    }
    @Test func unmeasurableResponsesRetainHistoryAndBadTimingRecoversAtNextBoundary() throws {
        var tracker = ThroughputTracker()
        try receive(&tracker, line("task_started")); try receive(&tracker, item("a", 0, 1000)); try receive(&tracker, usage("a"))
        let original = try #require(tracker.sample)
        try receive(&tracker, usage("no-model-items"))
        #expect(tracker.sample == original)
        try receive(&tracker, line("item_completed", ["item": ["id": "bad", "type": "Reasoning"]]))
        try receive(&tracker, item("same-response", 2000, 3000)); try receive(&tracker, usage("bad-timing", 900))
        #expect(tracker.sample == original)
        try receive(&tracker, item("recovered", 4000, 6000)); try receive(&tracker, usage("recovered", 300))
        #expect(tracker.sample?.tokensPerSecond == 150)
        try receive(&tracker, line("", ["response_id": "invalid-count", "usage": ["output_tokens": true]], type: "token_usage_record"))
        #expect(tracker.sample?.tokensPerSecond == 150)
        try receive(&tracker, item("after-invalid-count", 7000, 8000)); try receive(&tracker, usage("after-invalid-count", 250))
        #expect(tracker.sample?.tokensPerSecond == 250)
        try receive(&tracker, line("turn_aborted")); #expect(tracker.sample == nil)
        try receive(&tracker, item("after-abort", 8000, 9000)); try receive(&tracker, usage("after-abort"))
        #expect(tracker.sample == nil)
    }
    @Test func trustedTurnRecoveryDiscardsPartialResponseAndRejectsForeignBoundaries() throws {
        var tracker = ThroughputTracker(expectedTurn: ActivitySignal.hash("turn"))
        try receive(&tracker, line("task_started", ["turn_id": "foreign"]))
        try receive(&tracker, item("partial", 0, 1000))
        try receive(&tracker, line("", ["turn_id": "foreign", "response_id": "foreign", "usage": ["output_tokens": 100]], type: "token_usage_record"))
        try receive(&tracker, usage("boundary", 9999)); #expect(tracker.sample == nil)
        try receive(&tracker, item("complete", 2000, 4000))
        try receive(&tracker, usage("boundary", 9999)); #expect(tracker.sample == nil)
        try receive(&tracker, usage("complete", 200)); #expect(tracker.sample?.tokensPerSecond == 100)
        tracker.reset()
        try receive(&tracker, usage("new-boundary")); #expect(tracker.sample == nil)
        try receive(&tracker, item("after-reset", 5000, 6000)); try receive(&tracker, usage("after-reset", 150))
        #expect(tracker.sample?.tokensPerSecond == 150)
        tracker.reset()
        try receive(&tracker, line("turn_aborted")); try receive(&tracker, usage("aborted-boundary"))
        try receive(&tracker, item("aborted", 7000, 8000)); try receive(&tracker, usage("aborted"))
        #expect(tracker.sample == nil)
    }
    @Test func boundedTailRecoversTrustedTurnWithoutWaitingForAnotherUserPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-tps-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-tail-" + sessionID + ".jsonl")
        var bytes = try line("task_started")
        bytes.append(Data(("{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 4_300_000) + "\"}\n").utf8))
        bytes.append(try item("partial", 0, 1000)); bytes.append(try usage("boundary", 9999))
        try bytes.write(to: file)
        let reader = ThroughputReader(root: root), turns = [sessionHash: ActivitySignal.hash("turn")]
        for _ in 0..<5 { let result = await reader.read(turns: turns); #expect(result.samples.isEmpty && result.unavailable.isEmpty) }
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: item("complete", 5000, 7000)); try handle.write(contentsOf: usage("complete", 300)); try handle.close()
        let recovered = await reader.read(turns: turns)
        #expect(recovered.samples[sessionHash]?.tokensPerSecond == 150)
        let changedTurn = await reader.read(turns: [sessionHash: ActivitySignal.hash("next-turn")])
        #expect(changedTurn.samples.isEmpty)
    }
    @Test func unsafeTimingAndSamplesNeverInventZeroOrInfiniteSpeed() throws {
        for (start, end) in [(Int64(10), Int64(10)), (0, 49), (0, 600001)] {
            var tracker = ThroughputTracker()
            try receive(&tracker, line("task_started")); try receive(&tracker, item("a", start, end)); try receive(&tracker, usage("r"))
            #expect(tracker.sample == nil)
        }
        let invalid = ThroughputSample(tokensPerSecond: .nan, recordedAt: Date(), turn: "t")
        #expect(ThroughputPresentation(phase: .measured, sample: invalid).rateText == "—")
    }
    @Test func duplicateAndSymlinkRolloutNamesAreNotSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-tps-paths-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("rollout-a-" + sessionID + ".jsonl")
        let two = root.appendingPathComponent("rollout-b-" + sessionID + ".jsonl")
        var bytes = try line("task_started"); bytes.append(try item("a", 0, 1000)); bytes.append(try usage("r"))
        try bytes.write(to: one); try bytes.write(to: two)
        let reader = ThroughputReader(root: root)
        let duplicate = await reader.read(sessions: [sessionHash]); #expect(duplicate.unavailable.contains(sessionHash))
        try FileManager.default.removeItem(at: one)
        try FileManager.default.removeItem(at: two)
        let target = root.appendingPathComponent("other-file")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: one, withDestinationURL: target)
        await reader.reset()
        let symlink = await reader.read(sessions: [sessionHash]); #expect(symlink.samples.isEmpty && symlink.unavailable.contains(sessionHash))
    }
    @Test func boundedInitialTailWaitsForANewCompleteTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-tps-tail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-tail-" + sessionID + ".jsonl")
        var bytes = try line("task_started")
        bytes.append(Data(("{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 4_300_000) + "\"}\n").utf8))
        bytes.append(try item("partial", 0, 1000)); bytes.append(try usage("partial"))
        try bytes.write(to: file)
        let reader = ThroughputReader(root: root)
        for _ in 0..<5 {
            let result = await reader.read(sessions: [sessionHash]); #expect(result.samples.isEmpty)
        }
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        var complete = try line("task_started"); complete.append(try item("complete", 0, 1000)); complete.append(try usage("complete"))
        try handle.write(contentsOf: complete); try handle.close()
        let result = await reader.read(sessions: [sessionHash]); #expect(result.samples[sessionHash]?.tokensPerSecond == 100)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_TPS_LIVE"] != nil))
    func currentSessionReadOnlyMetadataProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        let id = try #require(environment["CODEX_THREAD_ID"])
        #expect(UUID(uuidString: id) != nil)
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let reader = ThroughputReader(root: home.appendingPathComponent("sessions"))
        let session = ActivitySignal.hash(id)
        var found = false, available = true
        for _ in 0..<5 {
            let result = await reader.read(sessions: [session])
            found = found || result.samples[session] != nil
            available = available && !result.unavailable.contains(session)
        }
        #expect(available && found)
        // Do not print rates, IDs, paths, timestamps, or raw rows from a real account.
        print("TPS metadata-only production reader: sourceAvailable=\(available), matchedSample=\(found)")
        await reader.reset()
    }
    @Test func incrementalReaderHandlesHalfLinesReplacementMissingAndPrivateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-tps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-test-" + sessionID + ".jsonl")
        var bytes = try line("task_started"); bytes.append(try item("a", 0, 1000))
        let response = try usage("r"); bytes.append(response.prefix(response.count / 2))
        try bytes.write(to: file); chmod(file.path, 0o600)
        let reader = ThroughputReader(root: root)
        let first = await reader.read(sessions: [sessionHash]); #expect(first.samples.isEmpty)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: response.suffix(response.count - response.count / 2)); try handle.close()
        let second = await reader.read(sessions: [sessionHash]); #expect(second.samples[sessionHash]?.tokensPerSecond == 100)
        let repeatRead = await reader.read(sessions: [sessionHash]); #expect(repeatRead.samples == second.samples)
        try Data("{\"type\":\"event_msg\"}\n".utf8).write(to: file)
        let truncated = await reader.read(sessions: [sessionHash]); #expect(truncated.samples.isEmpty)
        var replacement = try line("task_started"); replacement.append(try item("new", 0, 2000)); replacement.append(try usage("new-r", 400))
        try replacement.write(to: file, options: .atomic); chmod(file.path, 0o600)
        let replaced = await reader.read(sessions: [sessionHash]); #expect(replaced.samples[sessionHash]?.tokensPerSecond == 200)
        chmod(file.path, 0o666)
        let unsafe = await reader.read(sessions: [sessionHash]); #expect(unsafe.unavailable.contains(sessionHash)); #expect(unsafe.samples.isEmpty)
        try FileManager.default.removeItem(at: file)
        let missing = await reader.read(sessions: [sessionHash]); #expect(missing.samples.isEmpty)
        #expect(missing.unavailable.contains(sessionHash))
    }
}
