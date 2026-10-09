import CryptoKit
import Darwin
import Foundation

public enum ActivityEvent: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd"
    case start = "UserPromptSubmit", beforeTool = "PreToolUse", afterTool = "PostToolUse"
    case waiting = "PermissionRequest", stop = "Stop", interrupt = "Interrupt"
    case childStart = "SubagentStart", childStop = "SubagentStop"
    case compactStart = "PreCompact", compactEnd = "PostCompact"
}

/// PID 加启动时间绑定进程，防止 PID 复用让已退出的会话继续显示工作中。
public struct ActivityOwner: Codable, Equatable, Sendable {
    public let pid: Int32
    public let seconds: UInt64
    public let microseconds: UInt64
    public static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid() else { return nil }
        return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    public var isAlive: Bool { Self.read(pid) == self }
    public static func codexAncestor() -> Self? {
        var pid = getppid()
        for _ in 0..<20 {
            var path = [CChar](repeating: 0, count: 4096), info = proc_bsdinfo()
            guard pid > 1, proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            let name = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "/").last
            if name == "codex" { return Self.read(pid) }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }
}

/// 唯一跨进程载荷：事件、时间、哈希标识和进程生命期，无消息、路径或工具内容。
public struct ActivitySignal: Codable, Equatable, Sendable {
    public let version: Int
    public let event: ActivityEvent
    public let session: String
    public let turn: String?
    public let agent: String?
    public let tool: String?
    public let kind: String?
    public let time: Double
    public let owner: ActivityOwner
    public init(event: ActivityEvent, session: String, turn: String? = nil, agent: String? = nil,
                tool: String? = nil, kind: String? = nil, time: Double, owner: ActivityOwner) {
        version = 1; self.event = event; self.session = session; self.turn = turn
        self.agent = agent; self.tool = tool; self.kind = kind; self.time = time; self.owner = owner
    }
    public static func hash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func valid(now: Date) -> Bool {
        func hash(_ id: String) -> Bool { id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard version == 1, hash(session), [turn, agent, tool, kind].compactMap({ $0 }).allSatisfy(hash),
              time.isFinite, abs(now.timeIntervalSince1970 - time) <= 15, owner.pid > 0 else { return false }
        switch event {
        case .sessionStart, .sessionEnd: return true
        case .childStart, .childStop: return turn != nil && agent != nil
        case .beforeTool, .afterTool: return turn != nil && tool != nil
        case .waiting: return turn != nil && (tool != nil || kind != nil)
        default: return turn != nil
        }
    }
}

public struct ActivityLedger: Sendable {
    private struct Turn: Sendable {
        let id: String
        let owner: ActivityOwner
        var time: Double
        var waiting: Set<String> = []
        var waitingKinds: Set<String> = []
        var toolKinds: [String: String] = [:]
    }
    private struct Child: Sendable { let parent: String; let turn: String; let owner: ActivityOwner; var time: Double }
    private var turns: [String: Turn] = [:]
    private var children: [String: Child] = [:]
    // 完成事件优先于异步晚到的 start / tool；只在内存保留有界墓碑。
    private var ended: [String: Double] = [:]
    private var completedTools: [String: Double] = [:]
    private var closedSessions: Set<String> = []
    public init() {}
    public var isWorking: Bool {
        turns.values.contains { $0.waiting.isEmpty && $0.waitingKinds.isEmpty } || children.contains { key, _ in turns[key] == nil }
    }
    public var hasLiveEntries: Bool { !turns.isEmpty || !children.isEmpty }
    /// 显式本机验收只输出计数，不输出会话、调用或哈希标识。
    public var diagnosticCounts: [String: Int] {
        let waiting = turns.values.filter { !$0.waiting.isEmpty || !$0.waitingKinds.isEmpty }.count
        return ["activeTurns": turns.count, "waitingTurns": waiting, "workingTurns": turns.count - waiting,
                "independentChildren": children.filter { turns[$0.key] == nil }.count,
                "knownCalls": turns.values.reduce(0) { $0 + $1.toolKinds.count },
                "waitingCalls": turns.values.reduce(0) { $0 + $1.waiting.count },
                "waitingKinds": turns.values.reduce(0) { $0 + $1.waitingKinds.count }]
    }
    public func diagnosticRelations(to signal: ActivitySignal) -> [String: Int] {
        let active = turns[signal.session]
        return ["sameTurn": active?.id == signal.turn ? 1 : 0,
                "sameOwner": active?.owner == signal.owner ? 1 : 0,
                "endedTurn": ended[signal.session + ":" + (signal.turn ?? "")] == nil ? 0 : 1,
                "knownCall": signal.tool.map { active?.toolKinds[$0] != nil ? 1 : 0 } ?? 0,
                "waitingCall": signal.tool.map { active?.waiting.contains($0) == true ? 1 : 0 } ?? 0,
                "waitingKind": signal.kind.map { active?.waitingKinds.contains($0) == true ? 1 : 0 } ?? 0,
                "kindCandidates": signal.kind.map { kind in active?.toolKinds.values.filter { $0 == kind }.count ?? 0 } ?? 0,
                "olderThanActive": active.map { signal.time < $0.time ? 1 : 0 } ?? 0,
                "completedCall": signal.tool.map { completedTools[signal.session + ":" + (signal.turn ?? "") + ":" + $0] == nil ? 0 : 1 } ?? 0]
    }
    public mutating func receive(_ signal: ActivitySignal, now: Date) {
        guard signal.valid(now: now) else { return }
        let session = signal.session, key = session + ":" + (signal.turn ?? "")
        switch signal.event {
        case .sessionStart: closedSessions.remove(session) // 会话存在不等于正在推理。
        case .sessionEnd:
            if let active = turns[session], active.time > signal.time || active.owner != signal.owner { break }
            if closedSessions.count < 128 { closedSessions.insert(session) }
            if let turn = turns.removeValue(forKey: session) { ended[session + ":" + turn.id] = signal.time }
            children = children.filter { $0.key != session && $0.value.parent != session }
        case .stop, .interrupt:
            ended[key] = signal.time
            if turns[session]?.id == signal.turn { turns.removeValue(forKey: session) }
            children.removeValue(forKey: session)
            if signal.event == .interrupt { children = children.filter { $0.value.parent != session || $0.value.turn != signal.turn } }
        case .childStart:
            guard ended[key] == nil, let agent = signal.agent, let turn = signal.turn,
                  ended["agent:" + agent + ":" + turn] == nil else { break }
            if children.count < 128 { children[agent] = Child(parent: session, turn: turn, owner: signal.owner, time: signal.time) }
        case .childStop:
            guard let agent = signal.agent, let turn = signal.turn else { break }
            ended["agent:" + agent + ":" + turn] = signal.time
            if children[agent]?.parent == session && children[agent]?.turn == turn {
                children.removeValue(forKey: agent)
                if let active = turns.removeValue(forKey: agent) { ended[agent + ":" + active.id] = signal.time }
            }
        default:
            guard ended[key] == nil, let id = signal.turn else { break }
            // 后台 hook 可乱序；完成收据优先于同一工具晚到的许可等待。
            if signal.event == .waiting || signal.event == .beforeTool,
               let tool = signal.tool, completedTools[key + ":" + tool] != nil { break }
            if signal.event == .start { closedSessions.remove(session) }
            guard !closedSessions.contains(session) else { break }
            if var active = turns[session], active.id == id {
                guard active.owner == signal.owner,
                      signal.time >= active.time || signal.event == .waiting || signal.event == .afterTool || signal.event == .beforeTool else { break }
                active.time = max(active.time, signal.time)
                updateTool(signal, turn: &active)
                turns[session] = active
            } else if turns.count < 128, turns[session].map({ signal.time > $0.time }) ?? true {
                if let old = turns[session] { ended[session + ":" + old.id] = signal.time }
                var next = Turn(id: id, owner: signal.owner, time: signal.time)
                updateTool(signal, turn: &next)
                turns[session] = next
            }
        }
        if signal.event == .afterTool, let tool = signal.tool,
           turns[session]?.id == signal.turn, turns[session]?.owner == signal.owner {
            completedTools[key + ":" + tool] = signal.time
        }
        prune(now: now, alive: { _ in true })
    }
    private func updateTool(_ signal: ActivitySignal, turn: inout Turn) {
        if signal.event == .beforeTool, let tool = signal.tool, let kind = signal.kind,
           turn.toolKinds.count < 128 || turn.toolKinds[tool] != nil { turn.toolKinds[tool] = kind }
        if signal.event == .waiting {
            if let tool = signal.tool { turn.waiting.insert(tool) }
            else if let kind = signal.kind {
                // 没有调用 ID 时不能绑定“当前唯一”调用：对应 PreToolUse 可能仍在后台晚到。
                if turn.waitingKinds.count < 128 { turn.waitingKinds.insert(kind) }
            }
        }
        if signal.event == .afterTool, let tool = signal.tool {
            turn.waiting.remove(tool)
            let kind = turn.toolKinds.removeValue(forKey: tool) ?? signal.kind
            if let kind, !turn.toolKinds.values.contains(kind) { turn.waitingKinds.remove(kind) }
        }
    }
    public mutating func prune(now: Date, alive: (ActivityOwner) -> Bool = { $0.isAlive }) {
        // 30 分钟无生命周期事件视为未知，绝不将陈旧信号无限显示为工作中。
        let cutoff = now.timeIntervalSince1970 - 1800
        turns = turns.filter { $0.value.time >= cutoff && $0.value.time <= now.timeIntervalSince1970 + 15 && alive($0.value.owner) }
        children = children.filter { $0.value.time >= cutoff && alive($0.value.owner) }
        ended = ended.filter { $0.value >= cutoff }
        completedTools = completedTools.filter { $0.value >= cutoff }
        if ended.count > 512 { ended = Dictionary(uniqueKeysWithValues: ended.sorted { $0.value > $1.value }.prefix(512).map { ($0.key, $0.value) }) }
        if completedTools.count > 512 { completedTools = Dictionary(uniqueKeysWithValues: completedTools.sorted { $0.value > $1.value }.prefix(512).map { ($0.key, $0.value) }) }
    }
    public mutating func clear() { turns = [:]; children = [:]; ended = [:]; completedTools = [:]; closedSessions = [] }
}

/// 官方 hook stdin 的流式投影。跳过正文时不解码、不保存字符串或 JSON 树。
/// 只接受根对象的白名单字符串；不会打开 transcript_path 或任何会话文件。
public struct HookMetadata {
    public let event: ActivityEvent
    public let session: String
    public let turn: String?
    public let agent: String?
    public let tool: String?
    public let kind: String?
    public func signal(owner: ActivityOwner, time: Double) -> ActivitySignal {
        .init(event: event, session: ActivitySignal.hash(session), turn: turn.map(ActivitySignal.hash),
              agent: agent.map(ActivitySignal.hash), tool: tool.map(ActivitySignal.hash), kind: kind.map(ActivitySignal.hash), time: time, owner: owner)
    }
    public static func read(from handle: FileHandle, event: ActivityEvent) throws -> Self {
        var reader = MetadataReader(handle: handle)
        let fields = try reader.project()
        guard fields["hook_event_name"] == event.rawValue, let session = fields["session_id"], !session.isEmpty else { throw MetadataError.invalid }
        return Self(event: event, session: session, turn: fields["turn_id"], agent: fields["agent_id"], tool: fields["tool_use_id"], kind: fields["tool_name"])
    }
}

private enum MetadataError: Error { case invalid, limit }
private struct MetadataReader {
    let handle: FileHandle
    var rejectDuplicateKeys = false
    var buffer = Data()
    var offset = 0
    var total = 0
    var eof = false
    let whitelist: Set<String> = ["hook_event_name", "session_id", "turn_id", "agent_id", "tool_use_id", "tool_name"]
    mutating func peek() throws -> UInt8? {
        if offset == buffer.count, !eof {
            buffer = try handle.read(upToCount: 4096) ?? Data(); offset = 0; total += buffer.count
            guard total <= 32 * 1024 * 1024 else { throw MetadataError.limit }
            eof = buffer.isEmpty
        }
        return offset < buffer.count ? buffer[offset] : nil
    }
    mutating func take() throws -> UInt8? { let byte = try peek(); if byte != nil { offset += 1 }; return byte }
    mutating func spaces() throws { while let byte = try peek(), [9, 10, 13, 32].contains(byte) { offset += 1 } }
    mutating func expect(_ byte: UInt8) throws { try spaces(); guard try take() == byte else { throw MetadataError.invalid } }
    mutating func string(retain: Bool) throws -> String? {
        guard try take() == 34 else { throw MetadataError.invalid }
        var raw: [UInt8] = retain ? [34] : []
        while let byte = try take() {
            if retain { raw.append(byte); guard raw.count <= 1024 else { throw MetadataError.limit } }
            if byte == 34 { return retain ? try JSONDecoder().decode(String.self, from: Data(raw)) : nil }
            guard byte >= 32 else { throw MetadataError.invalid }
            if byte == 92 {
                guard let escaped = try take(), [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(escaped) else { throw MetadataError.invalid }
                if retain { raw.append(escaped) }
                if escaped == 117 {
                    for _ in 0..<4 {
                        guard let hex = try take(), (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw MetadataError.invalid }
                        if retain { raw.append(hex) }
                    }
                }
            }
        }
        throw MetadataError.invalid
    }
    mutating func skip(depth: Int) throws {
        guard depth <= 64 else { throw MetadataError.limit }
        try spaces()
        guard let first = try peek() else { throw MetadataError.invalid }
        switch first {
        case 34: _ = try string(retain: false)
        case 123, 91:
            let object = try take() == 123, end: UInt8 = object ? 125 : 93
            var keys: Set<String> = []
            try spaces(); if try peek() == end { _ = try take(); return }
            while true {
                if object {
                    try spaces(); let key = try string(retain: rejectDuplicateKeys)
                    if let key, !keys.insert(key).inserted { throw MetadataError.invalid }
                    try expect(58)
                }
                try skip(depth: depth + 1); try spaces()
                let delimiter = try take()
                if delimiter == end { return }
                guard delimiter == 44 else { throw MetadataError.invalid }
            }
        case 116, 102, 110:
            let word = first == 116 ? "true" : first == 102 ? "false" : "null"
            for byte in word.utf8 { guard try take() == byte else { throw MetadataError.invalid } }
        case 45, 48...57:
            var number: [UInt8] = []
            while let byte = try peek(), (48...57).contains(byte) || [45, 43, 46, 69, 101].contains(byte) {
                number.append(byte); offset += 1; guard number.count <= 128 else { throw MetadataError.limit }
            }
            _ = try JSONDecoder().decode(Double.self, from: Data(number))
        default: throw MetadataError.invalid
        }
    }
    mutating func project() throws -> [String: String] {
        try expect(123); try spaces()
        var fields: [String: String] = [:], seen: Set<String> = []
        if try peek() == 125 { _ = try take(); try spaces(); guard try peek() == nil else { throw MetadataError.invalid }; return [:] }
        while true {
            try spaces(); let key = try string(retain: true)!; try expect(58); try spaces()
            if rejectDuplicateKeys, !seen.insert(key).inserted { throw MetadataError.invalid }
            if whitelist.contains(key) {
                if !rejectDuplicateKeys { guard seen.insert(key).inserted else { throw MetadataError.invalid } }
                if try peek() == 34 {
                    let value = try string(retain: true)!
                    guard value.utf8.count <= 256, !value.isEmpty else { throw MetadataError.limit }
                    fields[key] = value
                } else { try skip(depth: 1) }
            } else { try skip(depth: 1) }
            try spaces(); let delimiter = try take()
            if delimiter == 125 { break }
            guard delimiter == 44 else { throw MetadataError.invalid }
        }
        try spaces(); guard try peek() == nil else { throw MetadataError.invalid }
        return fields
    }
}

public enum HookJSONValidation {
    public static func uniqueKeys(in handle: FileHandle) throws {
        var reader = MetadataReader(handle: handle, rejectDuplicateKeys: true)
        _ = try reader.project()
    }
}
