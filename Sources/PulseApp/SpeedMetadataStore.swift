import Combine
import Darwin
import Foundation
import PulseCore

/// Metadata-only connection to an existing official Unix WebSocket. Never starts a
/// daemon, resumes a thread, queries history, or writes Codex settings.
@MainActor final class SpeedMetadataStore: ObservableObject {
    @Published private(set) var tier: SpeedTier?
    private(set) var connected = false
    private(set) var failureReason: String?
    private var active: Set<String> = []
    private var known: [String: SpeedTier] = [:]
    private var enabled = false, suspended = false, upgraded = false
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?, writeSource: DispatchSourceWrite?
    private var http = Data(), outgoing = Data()
    private var decoder = LocalWebSocketDecoder()
    private var key = ""
    private var retry: Task<Void, Never>?, handshake: Task<Void, Never>?
    private var generation = 0
    private let socketURL: URL

    init(socket: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        socketURL = socket ?? home.appendingPathComponent("app-server-control/app-server-control.sock")
    }
    func setEnabled(_ value: Bool) { enabled = value; if value { start() } else { disconnect() } }
    func workingSessions(_ value: Set<String>) { active = value; publish() }
    func receive(_ update: SpeedMetadataUpdate) {
        if known.count >= 128, known[update.session] == nil { known = known.filter { active.contains($0.key) } }
        guard known.count < 128 || known[update.session] != nil else { return }
        known[update.session] = update.tier; publish()
    }
    private func publish() {
        let next = active.compactMap { known[$0] }.max { $0.rank < $1.rank }
        if tier != next { tier = next }
    }
    private func start() {
        guard enabled, !suspended, descriptor < 0 else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: socketURL.path)
        // The managed daemon publishes a user-owned symlink to its private socket.
        // Verify both entries and connect to the resolved socket, never an arbitrary file.
        let resolved = socketURL.resolvingSymlinksInPath()
        let target = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        guard (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              target?[.type] as? FileAttributeType == .typeSocket,
              (target?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((target?[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            failureReason = "socket-unavailable"; scheduleRetry(); return
        }
        var address = sockaddr_un()
        let path = Array(resolved.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { scheduleRetry(); return }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        // Nonblocking connect/write/read; no waits on the UI thread.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 || errno == EINPROGRESS else { failureReason = "connect-\(errno)"; Darwin.close(fd); scheduleRetry(); return }
        descriptor = fd; generation += 1; let token = generation
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { if self?.generation == token { self?.drain() } }
        }
        readSource = source; source.resume()
        key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        outgoing.append(Data(request.utf8)); flush()
        guard descriptor >= 0 else { return }
        handshake = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, generation == token, !connected else { return }
            failureReason = upgraded ? "initialize-timeout" : "upgrade-timeout"
            failed()
        }
    }
    private func send(_ object: [String: Any]) throws {
        guard descriptor >= 0 else { return }
        let data = try JSONSerialization.data(withJSONObject: object)
        outgoing.append(LocalWebSocketFrame.client(data)); flush()
    }
    private func flush() {
        guard descriptor >= 0 else { return }
        while !outgoing.isEmpty {
            let count = outgoing.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0 { outgoing.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOTCONN) {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
                    let token = generation
                    source.setEventHandler { [weak self] in
                        MainActor.assumeIsolated { if self?.generation == token { self?.flush() } }
                    }
                    writeSource = source; source.resume()
                }
                return
            } else { failed(); return }
        }
        writeSource?.cancel(); writeSource = nil
    }
    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 16384)
        for _ in 0..<64 {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 { consume(Data(bytes.prefix(count))); if descriptor < 0 { return } }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { failed(); return }
        }
    }
    private func consume(_ data: Data) {
        do {
            var framesData = data
            if !upgraded {
                http.append(data)
                guard http.count <= 8192 else { failed(); return }
                guard let end = http.range(of: Data("\r\n\r\n".utf8)) else { return }
                let header = String(decoding: http.prefix(upTo: end.upperBound), as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let accept = lines.first { $0.lowercased().hasPrefix("sec-websocket-accept:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true, accept == LocalWebSocketFrame.accept(for: key) else { failureReason = "upgrade-invalid"; failed(); return }
                framesData = Data(http.suffix(from: end.upperBound)); http = Data(); upgraded = true
                try send(["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "codex_pulse_speed", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"],
                    "capabilities": ["experimentalApi": true, "optOutNotificationMethods": Self.excludedNotifications]]])
            }
            for frame in try decoder.append(framesData) {
                if frame.opcode == 8 { failed(); return }
                if frame.opcode == 9 { outgoing.append(LocalWebSocketFrame.client(frame.payload, opcode: 10)); flush(); continue }
                guard frame.opcode == 1, let fields = try? SpeedJSONProjection.read(frame.payload) else { continue }
                if fields["id"] == "1", fields["method"] == nil {
                    guard fields["result"] != nil, fields["error"] == nil else { failureReason = "initialize-rejected"; failed(); return }
                    try send(["method": "initialized"]); connected = true; failureReason = nil; handshake?.cancel(); handshake = nil
                } else if fields["id"] != nil { failed(); return }
                else if connected, let update = SpeedMetadataUpdate.read(frame.payload) { receive(update) }
            }
        } catch { failureReason = "invalid-frame"; failed() }
    }
    private func failed() { disconnect(); scheduleRetry() }
    private func scheduleRetry() {
        guard enabled, !suspended, retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.retry = nil; self?.start()
        }
    }
    func suspend() { suspended = true; disconnect() }
    func resume() { suspended = false; start() }
    func stop() { enabled = false; disconnect() }
    private func disconnect() {
        generation += 1
        retry?.cancel(); retry = nil; handshake?.cancel(); handshake = nil
        readSource?.cancel(); readSource = nil; writeSource?.cancel(); writeSource = nil
        let fd = descriptor; descriptor = -1
        if fd >= 0 { Darwin.close(fd) }
        connected = false; known = [:]; publish(); upgraded = false
        http = Data(); outgoing = Data(); decoder = LocalWebSocketDecoder()
    }

    // Exclude content notifications at source; unknown future methods are still byte-skipped.
    private static let excludedNotifications: [String] = [
        "account/gatewayOAuth/changed",
        "account/login/completed",
        "account/rateLimits/updated",
        "account/updated",
        "app/list/updated",
        "autoApprovalReview/strictReviewRequired",
        "command/exec/outputDelta",
        "configWarning",
        "deprecationNotice",
        "error",
        "externalAgentConfig/import/completed",
        "externalAgentConfig/import/progress",
        "fs/changed",
        "fuzzyFileSearch/sessionCompleted",
        "fuzzyFileSearch/sessionUpdated",
        "guardianWarning",
        "hook/completed",
        "hook/started",
        "item/agentMessage/delta",
        "item/autoApprovalReview/completed",
        "item/autoApprovalReview/started",
        "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction",
        "item/completed",
        "item/fileChange/outputDelta",
        "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress",
        "item/plan/delta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "item/started",
        "mcpServer/event/stream/notification",
        "mcpServer/oauthLogin/completed",
        "mcpServer/startupStatus/updated",
        "model/rerouted",
        "model/safetyBuffering/updated",
        "model/verification",
        "modelProvider/authRecoveryCompleted",
        "modelProvider/authRecoveryStarted",
        "process/exited",
        "process/outputDelta",
        "project/changed",
        "remoteControl/status/changed",
        "serverRequest/resolved",
        "skills/changed",
        "thread/archived",
        "thread/attachment/updated",
        "thread/closed",
        "thread/compacted",
        "thread/deleted",
        "thread/environment/connected",
        "thread/environment/disconnected",
        "thread/goal/cleared",
        "thread/goal/updated",
        "thread/name/updated",
        "thread/prediction/updated",
        "thread/project/updated",
        "thread/queue/changed",
        "thread/realtime/closed",
        "thread/realtime/error",
        "thread/realtime/item/completed",
        "thread/realtime/item/started",
        "thread/realtime/item/transcript/delta",
        "thread/realtime/itemAdded",
        "thread/realtime/outputAudio/delta",
        "thread/realtime/sdp",
        "thread/realtime/started",
        "thread/realtime/transcript/delta",
        "thread/realtime/transcript/done",
        "thread/reverted",
        "thread/started",
        "thread/status/changed",
        "thread/tokenUsage/updated",
        "thread/unarchived",
        "turn/completed",
        "turn/diff/updated",
        "turn/moderationMetadata",
        "turn/plan/updated",
        "turn/started",
        "warning",
        "windows/worldWritableWarning",
        "windowsSandbox/setupCompleted",
    ]
}
