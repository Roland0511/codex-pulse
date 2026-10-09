import CryptoKit
import Foundation

/// 仅管理本应用启动的 stdio App Server；不接管桌面客户端或认证存储。
@MainActor public final class QuotaClient {
    public var onAccountChanged: (() -> Void)?
    public var onQuotaUpdated: (() -> Void)?
    public var onIdentity: ((String?) -> Void)?
    public private(set) var requestCount = 0
    public private(set) var quotaReadCount = 0
    public private(set) var processID: Int32?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var generation = 0
    private var initialized = false
    private var startup: Task<Void, Error>?
    private var startupID: UUID?
    private let inspectHooks: Bool
    public var isBusy: Bool { !pending.isEmpty || startup != nil }
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    public var executable: URL?
    public var timeoutSeconds: Double

    public init(executable: URL? = nil, timeoutSeconds: Double = 20, inspectHooks: Bool = false) {
        self.executable = executable; self.timeoutSeconds = timeoutSeconds; self.inspectHooks = inspectHooks
    }

    public static func discoverExecutable(preferred: String? = nil) -> URL? {
        let fm = FileManager.default
        var candidates = [preferred].compactMap { $0 }
        candidates += ["/Applications/Codex.app/Contents/Resources/codex",
                       "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                       "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        // Finder 不继承交互式 shell PATH；构建脚本写入本机发现路径作为提示。
        if let hint = Bundle.main.object(forInfoDictionaryKey: "PulseCodexExecutable") as? String { candidates.append(hint) }
        if let path = candidates.first(where: { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }) { return nativeExecutable(URL(fileURLWithPath: path)) }
        return nil
    }

    public static func nativeExecutable(_ selected: URL) -> URL {
        let resolved = selected.resolvingSymlinksInPath()
        guard resolved.lastPathComponent == "codex.js" else { return selected }
        let root = resolved.deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let platform = "codex-darwin-arm64", triple = "aarch64-apple-darwin"
        #else
        let platform = "codex-darwin-x64", triple = "x86_64-apple-darwin"
        #endif
        let suffix = "@openai/\(platform)/vendor/\(triple)/bin/codex"
        let candidates = [root.appendingPathComponent("node_modules/" + suffix),
                          root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(suffix),
                          root.appendingPathComponent("vendor/\(triple)/bin/codex")]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) ?? selected
    }

    private func start() async throws {
        if initialized, process?.isRunning == true { return }
        if let startup { try await startup.value; return }
        stop()
        let identifier = UUID()
        let task = Task { @MainActor in try await self.launch() }
        startup = task; startupID = identifier
        defer { if startupID == identifier { startup = nil; startupID = nil } }
        try await task.value
    }
    private func launch() async throws {
        guard let executable = executable ?? Self.discoverExecutable() else { throw QuotaError.executableMissing }
        let proc = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.executableURL = executable
        proc.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
        proc.standardInput = stdinPipe; proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice // 不记录可能携带身份信息的服务日志。
        // node 安装的 CLI 依赖 env node；Finder 启动时补入同目录。
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        proc.environment = environment
        let epoch = generation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch else { return }
                if data.isEmpty { self.disconnected() } else { self.receive(data) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch else { return }
                self.disconnected()
            }
        }
        do { try proc.run() } catch { stdoutPipe.fileHandleForReading.readabilityHandler = nil; throw QuotaError.executableMissing }
        process = proc; processID = proc.processIdentifier
        input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        var params: [String: Any] = ["clientInfo": ["name": "codex_pulse", "title": "Codex Pulse", "version": "0.1.0"]]
        if inspectHooks { params["capabilities"] = ["experimentalApi": true] }
        _ = try await request("initialize", params: params)
        try send(["method": "initialized", "params": [:]])
        initialized = true
    }

    public func read(now: Date = Date()) async throws -> QuotaSnapshot {
        try await start()
        let epoch = generation
        let before = try await accountIdentity()
        onIdentity?(before)
        let data = try await request("account/rateLimits/read")
        let after = try await accountIdentity()
        guard before == after, epoch == generation else { throw QuotaError.accountChanged }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let backend = root?["accountId"] as? String
        guard let boundKey = backend.map({ Self.digest("backend:" + $0) }) ?? before else { throw QuotaError.identityUnavailable }
        // 成功时间取响应完成时刻；测试可以使用显式时钟。
        return try QuotaSnapshot.parse(data, accountKey: boundKey, now: max(now, Date()))
    }

    private func accountIdentity() async throws -> String? {
        let data = try await request("account/read", params: ["refreshToken": false])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.invalidResponse }
        guard let account = root["account"] as? [String: Any] else { throw QuotaError.unauthenticated }
        guard account["type"] as? String == "chatgpt" else { throw QuotaError.unsupportedAccount }
        guard let email = account["email"] as? String, !email.isEmpty else { return nil }
        return Self.digest("chatgpt:" + email.lowercased())
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func readHookTrust(commands: Set<String>, cwd: URL) async throws -> HookTrustSummary {
        guard inspectHooks else { throw QuotaError.permissionDenied }
        try await start()
        return try HookTrustSummary.parse(try await request("hooks/list", params: ["cwds": [cwd.path]]), commands: commands)
    }

    private func request(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        guard ["initialize", "account/read", "account/rateLimits/read"].contains(method) || (inspectHooks && method == "hooks/list") else { throw QuotaError.permissionDenied }
        sequence += 1
        let id = sequence
        let epoch = generation
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.timeoutSeconds ?? 20)) } catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    self.stop(error: .timedOut)
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                do {
                    try send(message); requestCount += 1
                    if method == "account/rateLimits/read" { quotaReadCount += 1 }
                } catch { stop(error: .disconnected) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch, self.pending[id] != nil else { return }
                self.stop(error: .disconnected)
            }
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else { throw QuotaError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 4 * 1024 * 1024 else { stop(error: .invalidResponse); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let item = pending.removeValue(forKey: id) {
                item.timeout.cancel()
                if let error = object["error"] as? [String: Any] {
                    let text = (error["message"] as? String ?? "").lowercased()
                    let code = error["code"] as? Int
                    let failure: QuotaError = code == 401 || text.contains("unauth") || text.contains("401") || text.contains("login")
                        ? .unauthenticated : (code == 403 || text.contains("403") || text.contains("permission") || text.contains("forbidden") ? .permissionDenied : .serviceUnavailable)
                    item.continuation.resume(throwing: failure)
                } else if let result = object["result"], let encoded = try? JSONSerialization.data(withJSONObject: result) {
                    item.continuation.resume(returning: encoded)
                } else { item.continuation.resume(throwing: QuotaError.invalidResponse) }
            } else if let method = object["method"] as? String {
                if method == "account/updated" { onAccountChanged?() }
                if method == "account/rateLimits/updated" { onQuotaUpdated?() }
                // 拒绝任何服务主动发来的请求，不提供外部凭据或执行批准。
                if let id = object["id"] {
                    try? send(["id": id, "error": ["code": -32601, "message": "Codex Pulse is read-only"]])
                }
            }
        }
    }

    private func disconnected() { stop(error: .disconnected) }

    public func stop(error: QuotaError = .disconnected) {
        startup?.cancel(); startup = nil; startupID = nil
        generation += 1; initialized = false
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; buffer.removeAll(keepingCapacity: false)
        let old = process
        process = nil; processID = nil
        old?.terminationHandler = nil
        if let old, old.isRunning {
            old.terminate()
            // 仅终止本应用持有的 Process；异步有限等待后强制回收。
            DispatchQueue.global(qos: .utility).async {
                for _ in 0..<20 {
                    if !old.isRunning { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
                old.waitUntilExit()
            }
        }
        let waiters = pending; pending = [:]
        for item in waiters.values { item.timeout.cancel(); item.continuation.resume(throwing: error) }
    }
}
