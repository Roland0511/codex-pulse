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
        import sys,json,time
        mode='\(mode)'
        reads=0
        for line in sys.stdin:
            m=json.loads(line)
            with open('\(log.path)','a') as f: f.write(m['method']+'\\n')
            if 'id' not in m: continue
            method=m['method']
            result={}
            if method=='initialize' and mode=='concurrent': time.sleep(0.15)
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
        return (QuotaClient(executable: executable, timeoutSeconds: mode == "timeout" ? 0.8 : 5, inspectHooks: hooks), directory, log)
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
}
