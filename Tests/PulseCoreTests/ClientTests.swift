import Foundation
import Testing
@testable import PulseCore

@Suite("stdio 连接生命周期", .serialized) @MainActor struct ClientTests {
    private func fake(_ mode: String, hooks: Bool = false) throws -> (QuotaClient, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        let log = directory.appendingPathComponent("methods.jsonl")
        let script = """
        #!/usr/bin/python3
        import sys,json,time,pathlib,os
        mode='\(mode)'
        settings=dict(arg.split('=',1) for arg in sys.argv[1:] if '=' in arg)
        catalog=settings.get('model_catalog_json')
        with open('\(directory.path)/launches.jsonl','a') as f:
            f.write(json.dumps({'arguments':sys.argv[1:],'settings':settings,'sqliteEnvironment':os.environ.get('CODEX_SQLITE_HOME')})+'\\n')
        if mode=='reject-config': sys.exit(1)
        if catalog:
            json.loads(pathlib.Path(json.loads(catalog)).read_text())
        else:
            pathlib.Path('\(directory.path)/shared-model-cache.json').write_text('overwritten')
        reads=0
        for line in sys.stdin:
            m=json.loads(line)
            with open('\(log.path)','a') as f: f.write(m['method']+'\\n')
            if 'id' not in m: continue
            method=m['method']
            result={}
            if method=='initialize' and mode=='concurrent': time.sleep(0.15)
            if method=='initialize' and mode in ['slow-start', 'stuck-start']: time.sleep(21 if mode=='slow-start' else 30)
            if method=='hooks/list': result={'data':[]}
            if method=='account/read':
                reads+=1
                email='fixture-a@example.invalid' if mode!='switch' or reads==1 else 'fixture-b@example.invalid'
                result={'account':None if mode=='logout' else {'type':'chatgpt','email':None if mode in ['no-email','no-identity'] else email,'planType':'pro'}}
            elif method=='account/rateLimits/read':
                if mode=='timeout': time.sleep(3)
                if mode=='exit': sys.exit(0)
                result={'rateLimits':{'primary':{'usedPercent':22,'windowDurationMins':10080,'resetsAt':1894057200}}}
                if mode=='no-email':result['accountId']='synthetic-backend-account'
            response={'id':m['id'],'result':result}
            if method=='account/rateLimits/read' and mode=='permission': response={'id':m['id'],'error':{'code':403,'message':'permission denied'}}
            encoded=json.dumps(response)+'\\n'
            sys.stdout.write(encoded[:5]);sys.stdout.flush()
            sys.stdout.write(encoded[5:]);sys.stdout.flush()
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = QuotaClient(executable: executable, timeoutSeconds: mode == "timeout" ? 0.8 : 5, inspectHooks: hooks)
        client.stateRoot = directory.appendingPathComponent("state")
        return (client, directory, log)
    }
    @Test func fragmentedReadAndReuseOnlyReadMethods() async throws {
        let (client, directory, log) = try fake("normal")
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        let first = try await client.read(), pid = client.processID
        #expect(first.selectedWindow?.remainingPercent == 78)
        #expect(first.selectedWindow?.durationMinutes == 10080)
        _ = try await client.read()
        #expect(client.processID == pid)
        #expect(client.quotaReadCount == 2)
        let methods = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        #expect(Set(methods) == ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        client.stop(); #expect(client.processID == nil)
        if let pid {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while kill(pid, 0) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(kill(pid, 0) != 0)
        }
    }
    @Test(arguments: ["timeout", "exit", "permission", "logout", "switch", "no-identity"])
    func failuresReturnAndRelease(_ mode: String) async throws {
        let (client, directory, _) = try fake(mode)
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        do { _ = try await client.read(); Issue.record("预期失败：\(mode)") }
        catch {
            let expected: QuotaError = mode == "timeout" ? .timedOut : mode == "exit" ? .disconnected :
                mode == "permission" ? .permissionDenied : mode == "logout" ? .unauthenticated : mode == "no-identity" ? .identityUnavailable : .accountChanged
            #expect(error as? QuotaError == expected)
        }
        client.stop(); #expect(client.processID == nil)
    }
    @Test func missingExecutableHasActionableState() async {
        let client = QuotaClient(executable: URL(fileURLWithPath: "/synthetic/missing/codex"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        client.stateRoot = root
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await client.read(); Issue.record("不存在的可执行文件不应成功") }
        catch { #expect(error as? QuotaError == .executableMissing) }
        #expect(client.processID == nil)
    }
    @Test func backendIdentitySupportsUnavailableEmail() async throws {
        let (client, directory, _) = try fake("no-email")
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await client.read()
        #expect(snapshot.accountKey == QuotaClient.digest("backend:synthetic-backend-account"))
        #expect(snapshot.selectedWindow?.remainingPercent == 78)
    }
    @Test func concurrentQuotaAndTrustChecksShareOneInitializedService() async throws {
        let (client, directory, log) = try fake("concurrent", hooks: true)
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        async let quota = client.read()
        async let trust = client.readHookTrust(commands: ["synthetic"], cwd: directory)
        let result = try await (quota, trust)
        #expect(result.0.selectedWindow?.remainingPercent == 78 && result.1.found == 0)
        #expect(!client.isBusy && client.processID != nil)
        let methods = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        #expect(methods.filter { $0 == "hooks/list" }.count == 1)
        #expect(Set(methods) == ["initialize", "initialized", "hooks/list", "account/read", "account/rateLimits/read"])
    }

    @Test func startupReuseAndRestartProtectSharedCacheAndCleanPrivateRuntime() async throws {
        let (client, directory, _) = try fake("normal", hooks: true)
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("shared-model-cache.json")
        try Data("synthetic main-client model capabilities".utf8).write(to: cache)
        let before = try Data(contentsOf: cache)
        let modified = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try await client.read()
        _ = try await client.read()
        client.stop()
        _ = try await client.read()
        _ = try await client.readHookTrust(commands: [], cwd: directory)
        let data = try String(contentsOf: directory.appendingPathComponent("launches.jsonl"), encoding: .utf8)
        let launches = try data.split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(launches.count == 2)
        var directories: [URL] = [], databases: [URL] = []
        for launch in launches {
            let arguments = try #require(launch["arguments"] as? [String])
            #expect(arguments.contains("--strict-config"))
            let settings = try #require(launch["settings"] as? [String: String])
            #expect(settings.values.allSatisfy { !$0.contains("\\/") })
            func path(_ key: String) throws -> String {
                try JSONDecoder().decode(String.self, from: Data(try #require(settings[key]).utf8))
            }
            let database = URL(fileURLWithPath: try path("sqlite_home"))
            let runtime = URL(fileURLWithPath: try path("model_catalog_json")).deletingLastPathComponent()
            directories.append(runtime)
            databases.append(database)
            #expect(launch["sqliteEnvironment"] as? String == database.path)
            #expect(try path("model_catalog_json") == runtime.appendingPathComponent("models.json").path)
            #expect(try path("log_dir") == runtime.appendingPathComponent("log").path)
        }
        #expect(directories[0] != directories[1])
        #expect(databases[0] == databases[1] && databases[0] != directories[0])
        #expect(try Data(contentsOf: cache) == before)
        #expect(try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        client.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while directories.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: databases[0].path))
    }

    @Test func initializationCanExceedTwentySecondsWithoutExtendingRPCDeadline() async throws {
        let (client, directory, _) = try fake("slow-start")
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        client.timeoutSeconds = 1
        client.initializationTimeoutSeconds = 25
        let snapshot = try await client.read()
        #expect(snapshot.selectedWindow?.remainingPercent == 78)
    }

    @Test(arguments: [false, true])
    func databaseLockWaitIsBoundedAndCancellable(cancel: Bool) async throws {
        let (client, directory, _) = try fake("normal")
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        let holder = try QuotaServerConfiguration(executable: try #require(client.executable),
            environment: ProcessInfo.processInfo.environment, stateRoot: client.stateRoot)
        defer { holder.remove() }
        #expect(try holder.acquire())
        client.initializationTimeoutSeconds = cancel ? 60 : 0.2
        let task = Task { try await client.read() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.processID == nil)
        if cancel { task.cancel() }
        do { _ = try await task.value; Issue.record("锁等待应当取消或超时") }
        catch { if !cancel { #expect(error as? QuotaError == .timedOut) } }
        #expect(!client.isBusy)
        holder.remove()
        client.initializationTimeoutSeconds = 5
        #expect(try await client.read().selectedWindow?.remainingPercent == 78)
    }

    @Test(arguments: [false, true])
    func initializationTimeoutAndCallerCancellationReapProcess(cancel: Bool) async throws {
        let (client, directory, log) = try fake("stuck-start")
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        client.initializationTimeoutSeconds = cancel ? 60 : 0.5
        let task = Task { try await client.read() }
        while !FileManager.default.fileExists(atPath: log.path) { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(client.processID)
        if cancel { task.cancel() }
        do { _ = try await task.value; Issue.record("初始化应当取消或超时") }
        catch { if !cancel { #expect(error as? QuotaError == .timedOut) } }
        #expect(!client.isBusy && client.processID == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
    }

    @Test func unsupportedConfigurationNeverFallsBackToUnprotectedServer() async throws {
        let (client, directory, _) = try fake("reject-config")
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        do { _ = try await client.read(); Issue.record("拒绝隔离配置时不应查询成功") }
        catch { #expect(error as? QuotaError == .disconnected) }
        #expect(client.processID == nil)
        let launches = try String(contentsOf: directory.appendingPathComponent("launches.jsonl"), encoding: .utf8)
        #expect(launches.split(separator: "\n").count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("shared-model-cache.json").path))
    }

    // 由 test_quota_server.py 在合成 CODEX_HOME / HTTPS 后端中显式启用。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_TEST_CODEX"] != nil))
    func realCLIWithSyntheticBackend() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["PULSE_TEST_CODEX"])
        let client = QuotaClient(executable: URL(fileURLWithPath: executable))
        client.stateRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CODEX_HOME"])).appendingPathComponent("pulse-state")
        defer { client.stop() }
        let first = try await client.read()
        #expect(first.selectedWindow?.remainingPercent == 78)
        #expect(first.selectedWindow?.durationMinutes == 10080)
        _ = try await client.read()
        #expect(client.quotaReadCount == 2 && client.requestCount == 7)
    }
}
