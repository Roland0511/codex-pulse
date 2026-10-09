import Darwin
import Foundation
import Testing
@testable import PulseCore

@Suite("工作状态与正文隔离") struct ActivityTests {
    let now = Date(timeIntervalSince1970: 1894000000)
    var owner: ActivityOwner { ActivityOwner.read(getpid())! }
    func event(_ name: ActivityEvent, session: String = "one", turn: String = "turn", agent: String? = nil,
               tool: String? = nil, kind: String? = nil, offset: Double = 0) -> ActivitySignal {
        .init(event: name, session: ActivitySignal.hash(session), turn: ActivitySignal.hash(turn),
              agent: agent.map(ActivitySignal.hash), tool: tool.map(ActivitySignal.hash), kind: kind.map(ActivitySignal.hash),
              time: now.timeIntervalSince1970 + offset, owner: owner)
    }
    @Test func overlappingTurnsAndLateStopCannotStopAnotherTurn() {
        var ledger = ActivityLedger()
        ledger.receive(event(.start), now: now)
        ledger.receive(event(.start, session: "two"), now: now)
        ledger.receive(event(.stop), now: now)
        #expect(ledger.isWorking)
        ledger.receive(event(.start, session: "two", turn: "new", offset: 1), now: now.addingTimeInterval(1))
        ledger.receive(event(.stop, session: "two"), now: now)
        #expect(ledger.isWorking)
        ledger.receive(event(.stop, session: "two", turn: "new", offset: 2), now: now.addingTimeInterval(2))
        #expect(!ledger.isWorking)
    }
    @Test func lateAsyncToolAndChildStartCannotResurrectCompletedWork() {
        var ledger = ActivityLedger()
        ledger.receive(event(.stop), now: now)
        ledger.receive(event(.beforeTool, tool: "tool", offset: 1), now: now.addingTimeInterval(1))
        #expect(!ledger.isWorking)
        ledger.receive(event(.childStop, session: "other", agent: "child"), now: now)
        ledger.receive(event(.childStart, session: "other", agent: "child", offset: 1), now: now.addingTimeInterval(1))
        #expect(!ledger.isWorking)
    }
    @Test func waitingResumesOnlyAfterTheSameToolAndChildIsIndependent() {
        var ledger = ActivityLedger()
        ledger.receive(event(.start), now: now)
        ledger.receive(event(.waiting, tool: "permission", offset: 1), now: now.addingTimeInterval(1))
        #expect(!ledger.isWorking)
        ledger.receive(event(.beforeTool, tool: "permission", offset: 2), now: now.addingTimeInterval(2))
        ledger.receive(event(.afterTool, tool: "other", offset: 3), now: now.addingTimeInterval(3))
        #expect(!ledger.isWorking)
        ledger.receive(event(.childStart, agent: "child", offset: 4), now: now.addingTimeInterval(4))
        #expect(ledger.isWorking)
        ledger.receive(event(.childStop, agent: "child", offset: 5), now: now.addingTimeInterval(5))
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "permission", offset: 6), now: now.addingTimeInterval(6))
        #expect(ledger.isWorking)
        ledger.receive(event(.interrupt, offset: 7), now: now.addingTimeInterval(7))
        #expect(!ledger.isWorking)
    }
    @Test func latePermissionForCompletedToolCannotPauseNewWork() {
        var ledger = ActivityLedger()
        ledger.receive(event(.start), now: now)
        ledger.receive(event(.afterTool, tool: "finished", offset: 1), now: now.addingTimeInterval(1))
        ledger.receive(event(.waiting, tool: "finished", offset: 2), now: now.addingTimeInterval(2))
        #expect(ledger.isWorking)
        ledger.receive(event(.waiting, tool: "pending", offset: 3), now: now.addingTimeInterval(3))
        ledger.receive(event(.afterTool, tool: "finished", offset: 4), now: now.addingTimeInterval(4))
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "pending", offset: 5), now: now.addingTimeInterval(5))
        #expect(ledger.isWorking)
    }
    @Test func unrelatedToolTimestampCannotDiscardMatchingWaitOrCompletion() {
        var ledger = ActivityLedger()
        ledger.receive(event(.start), now: now)
        ledger.receive(event(.beforeTool, tool: "other", offset: 2), now: now.addingTimeInterval(2))
        // 到达顺序与产生时间不同，仍须接纳尚未完成的等待。
        ledger.receive(event(.waiting, tool: "permission", offset: 1), now: now.addingTimeInterval(2))
        #expect(!ledger.isWorking)
        ledger.receive(event(.beforeTool, tool: "other", offset: 4), now: now.addingTimeInterval(4))
        ledger.receive(event(.afterTool, tool: "permission", offset: 3), now: now.addingTimeInterval(4))
        #expect(ledger.isWorking)
    }
    @Test func officialPermissionPayloadWithoutCallIDIsAcceptedAndPrivate() throws {
        let input = #"{"hook_event_name":"PermissionRequest","session_id":"synthetic","turn_id":"turn","tool_name":"Bash","tool_input":{"command":"must never retain this command"}}"#
        let metadata = try parse(input, event: .waiting)
        let signal = metadata.signal(owner: owner, time: now.timeIntervalSince1970)
        #expect(signal.valid(now: now) && signal.tool == nil && signal.kind == ActivitySignal.hash("Bash"))
        let encoded = String(decoding: try JSONEncoder().encode(signal), as: UTF8.self)
        #expect(!encoded.contains("Bash") && !encoded.contains("command") && !encoded.contains("synthetic"))
    }
    @Test func permissionWithoutIDWaitsForMatchingKind() {
        var ledger = ActivityLedger()
        ledger.receive(event(.beforeTool, tool: "one", kind: "Bash"), now: now)
        ledger.receive(event(.waiting, kind: "Bash", offset: 1), now: now.addingTimeInterval(1))
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "unrelated", kind: "Other", offset: 2), now: now.addingTimeInterval(2))
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "one", kind: "Bash", offset: 3), now: now.addingTimeInterval(3))
        #expect(ledger.isWorking)
    }
    @Test func permissionBeforeItsOwnLatePreToolDoesNotBindAnotherCall() {
        var ledger = ActivityLedger()
        ledger.receive(event(.beforeTool, tool: "other", kind: "Bash", offset: 2), now: now.addingTimeInterval(2))
        ledger.receive(event(.waiting, kind: "Bash", offset: 4), now: now.addingTimeInterval(4))
        // 对应调用的后台 PreToolUse 比许可更早产生，却更晚到达。
        ledger.receive(event(.beforeTool, tool: "approved", kind: "Bash", offset: 3), now: now.addingTimeInterval(4))
        #expect(ledger.diagnosticCounts["knownCalls"] == 2)
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "other", kind: "Bash", offset: 5), now: now.addingTimeInterval(5))
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "approved", kind: "Bash", offset: 6), now: now.addingTimeInterval(6))
        #expect(ledger.isWorking)
    }
    @Test func ambiguousPermissionWaitsForAllKnownCallsOfThatKind() {
        var ledger = ActivityLedger()
        ledger.receive(event(.beforeTool, tool: "one", kind: "Bash"), now: now)
        ledger.receive(event(.beforeTool, tool: "two", kind: "Bash", offset: 1), now: now.addingTimeInterval(1))
        ledger.receive(event(.waiting, kind: "Bash", offset: 2), now: now.addingTimeInterval(2))
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "one", kind: "Bash", offset: 3), now: now.addingTimeInterval(3))
        #expect(!ledger.isWorking)
        ledger.receive(event(.afterTool, tool: "two", kind: "Bash", offset: 4), now: now.addingTimeInterval(4))
        #expect(ledger.isWorking)
    }
    @Test func unknownOldInvalidOrDeadSourceNeverStaysBusy() {
        var ledger = ActivityLedger()
        ledger.receive(event(.sessionStart), now: now)
        #expect(!ledger.isWorking)
        ledger.receive(event(.start, offset: -16), now: now)
        #expect(!ledger.isWorking)
        ledger.receive(event(.start), now: now)
        ledger.prune(now: now, alive: { _ in false })
        #expect(!ledger.isWorking)
        ledger.receive(event(.start), now: now)
        ledger.prune(now: now.addingTimeInterval(1801), alive: { _ in true })
        #expect(!ledger.isWorking)
        let raw = ActivitySignal(event: .start, session: "not-a-hash", turn: "not-a-hash", time: now.timeIntervalSince1970, owner: owner)
        #expect(!raw.valid(now: now))
        #expect(owner.isAlive)
    }
    func parse(_ json: String, event: ActivityEvent = .beforeTool) throws -> HookMetadata {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try HookMetadata.read(from: handle, event: event)
    }
    @Test func largeNestedBodyIsSkippedAndOnlyMetadataIsHashed() throws {
        let body = String(repeating: "敏感合成正文", count: 30000)
        let input: [String: Any] = ["session_id": "synthetic-session", "turn_id": "synthetic-turn", "tool_use_id": "synthetic-tool",
            "hook_event_name": "PreToolUse", "transcript_path": "/must/not/be/opened", "prompt": body,
            "tool_input": ["session_id": "nested-forgery", "array": [true, NSNull(), -1.5, ["response": body]]], "last_assistant_message": body]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let signal = try parse(json).signal(owner: owner, time: now.timeIntervalSince1970)
        #expect(signal.session == ActivitySignal.hash("synthetic-session"))
        #expect(signal.turn == ActivitySignal.hash("synthetic-turn"))
        #expect(signal.valid(now: now))
        let encoded = String(decoding: try JSONEncoder().encode(signal), as: UTF8.self)
        #expect(encoded.utf8.count < 1024 && !encoded.contains("敏感") && !encoded.contains("synthetic-session") && !encoded.contains("transcript"))
    }
    @Test func malformedDuplicateOrMismatchedMetadataFailsClosed() {
        for input in ["{", "{\"prompt\":[", "{\"session_id\":\"a\",\"session_id\":\"b\"}",
                      "{\"session_id\":\"a\",\"hook_event_name\":\"Stop\"}",
                      "{\"session_id\":\"a\",\"hook_event_name\":\"PreToolUse\"} trailing"] {
            #expect(throws: (any Error).self) { _ = try parse(input) }
        }
    }
    @Test func metadataAfterSkippedValueAndEscapedKeysAreRecognized() throws {
        let metadata = try parse(#"{"prompt":{"ignored":["session_id",true,null,2]},"session\u005fid":"one","turn_id":"turn","tool_use_id":"call","hook_event_name":"PreToolUse"}"#)
        #expect(metadata.session == "one" && metadata.tool == "call")
    }
}
