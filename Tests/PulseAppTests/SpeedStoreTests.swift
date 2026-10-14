import AppKit
import Combine
import QuartzCore
@testable import PulseCore
import Testing
@testable import PulseApp

@Suite("速度配置与并行状态", .serialized) @MainActor struct SpeedStoreTests {
    @Test func atomicConfigChangesDeletionAndAppearanceIndependence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.toml")
        try "service_tier='priority'".write(to: file, atomically: true, encoding: .utf8)
        let store = AppearanceStore(url: file)
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.start("system")
        #expect(store.speed.tier == .fast && store.codex == nil)
        try "service_tier='ultrafast'".write(to: file, atomically: true, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.speed.tier != .ultrafast && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.speed.tier == .ultrafast)
        try FileManager.default.removeItem(at: file)
        store.reload(force: true); #expect(store.speed.tier == .unknown)
    }
    @Test func highestConfirmedWorkingSessionWinsAndStopDropsTier() {
        let store = SpeedMetadataStore()
        defer { store.stop() }
        store.receive(.init(session: "one", tier: .fast))
        store.receive(.init(session: "two", tier: .ultrafast))
        #expect(store.tier == nil)
        store.workingSessions(["one", "two"]); #expect(store.tier == .ultrafast)
        store.workingSessions(["one"]); #expect(store.tier == .fast)
        store.workingSessions(["unknown"]); #expect(store.tier == nil)
        store.workingSessions(["two"]); store.suspend(); #expect(store.tier == nil)
    }
    @Test func lightningLayersStayInsideFilledWidthAndDetachStopsAnimations() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 28, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
        let view = ConsumptionTraceLayerView(frame: CGRect(x: 0, y: 0, width: 28, height: 10))
        window.contentView = view
        defer { window.contentView = nil; window.orderOut(nil) }
        view.layoutSubtreeIfNeeded(); view.setSpeed(.fast)
        #expect(view.arcs.count == DesignTokens.fastLightningBurstStartsSeconds.count * 2)
        let weak = try #require(view.arcs.first { $0.name == "trunk-core" })
        #expect(abs(Double(weak.lineWidth) - DesignTokens.fastLightningStrokeWidth * DesignTokens.lightningCompactStrokeBoost) < 0.00001)
        for arc in view.arcs {
            let rect = try #require(arc.path?.boundingBoxOfPath)
            #expect(rect.minX >= 0 && rect.maxX <= view.bounds.width)
            #expect(rect.minY >= 0 && rect.maxY <= view.bounds.height)
            #expect(arc.animation(forKey: "lightning") != nil)
        }
        let fastCount = view.arcs.count
        view.setSpeed(.ultrafast)
        #expect(abs(Double(try #require(view.arcs.first { $0.name == "trunk-core" }).lineWidth) - DesignTokens.ultrafastLightningStrokeWidth * DesignTokens.lightningCompactStrokeBoost) < 0.00001)
        #expect(view.arcs.count > fastCount)
        view.setSignal(.systemBlue)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            view.setSurface(appearance == .aqua ? .white : .black)
            for arc in view.arcs {
                let color = try #require(arc.strokeColor?.components)
                #expect(color[0] > color[1] && color[1] > color[2]) // Gold remains independent of the blue fill.
                let group = try #require(arc.animation(forKey: "lightning") as? CAAnimationGroup)
                for animation in group.animations?.compactMap({ $0 as? CAKeyframeAnimation }) ?? [] {
                    let times = try #require(animation.keyTimes).map(\.doubleValue)
                    #expect(times.first == 0 && times.last == 1)
                    #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
                    #expect(animation.values?.count == times.count)
                }
                let morph = try #require(group.animations?.compactMap { $0 as? CAKeyframeAnimation }.first { $0.keyPath == "path" })
                for path in try #require(morph.values as? [CGPath]) {
                    let rect = path.boundingBoxOfPath
                    #expect(rect.minX >= 0 && rect.maxX <= view.bounds.width)
                    #expect(rect.minY >= 0 && rect.maxY <= view.bounds.height)
                }
            }
        }
        // A custom dark Codex surface can be used while macOS reports Aqua.
        view.appearance = NSAppearance(named: .aqua); view.setSurface(.black)
        let core = try #require(view.arcs.first { $0.name == "trunk-core" })
        #expect(try #require(core.strokeColor?.components)[0] > 0.9)
        view.setSurface(.white)
        #expect(try #require(core.strokeColor?.components)[0] < 0.9)
        view.setSpeed(.standard); #expect(view.arcs.isEmpty)
        view.setSpeed(.ultrafast); window.contentView = nil
        #expect(view.arcs.allSatisfy { $0.animationKeys() == nil })
    }

    @Test func flowingHeadAndFilledTrackShareAxisAtFractionalSizes() throws {
        _ = NSApplication.shared
        for height in [10.0, 10.5, 11.0] {
            let window = NSWindow(contentRect: CGRect(x: 50.5, y: 50.5, width: 31.25, height: height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            let view = ConsumptionTraceLayerView(frame: CGRect(x: 0, y: 0, width: 31.25, height: height))
            window.contentView = view; view.layoutSubtreeIfNeeded()
            for speed in [SpeedTier.standard, .fast, .ultrafast] {
                view.setSpeed(speed)
                let root = try #require(view.layer)
                let flow = try #require(root.sublayers?.first { $0.name == "moving-flow" })
                let head = try #require(flow.sublayers?.first { $0.name == "flow-head" })
                let headCenter = head.convert(CGPoint(x: head.bounds.midX, y: head.bounds.midY), to: root)
                #expect(abs(headCenter.y - view.filled.frame.midY) < 0.00001)
                #expect(view.filled.frame.midY == view.bounds.midY)
            }
            window.contentView = nil; window.orderOut(nil)
        }
    }

    @Test func metadataSocketOnlyInitializesAndClearsOnDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("server.py"), socket = directory.appendingPathComponent("metadata.sock")
        let record = directory.appendingPathComponent("requests.txt")
        let id = "123e4567-e89b-12d3-a456-426614174000"
        let script = """
        import json, socket, struct, hashlib, base64, os
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind("\(socket.path)"); os.chmod("\(socket.path)",0o600); server.listen(1)
        conn, _ = server.accept(); conn.settimeout(5)
        def exact(n):
            result = b''
            while len(result) < n:
                chunk = conn.recv(n-len(result))
                if not chunk: raise EOFError()
                result += chunk
            return result
        def receive():
            header = exact(2); size = header[1] & 127
            if size == 126: size = struct.unpack('!H',exact(2))[0]
            if size == 127: size = struct.unpack('!Q',exact(8))[0]
            assert header[1] & 128
            mask = exact(4); data = exact(size)
            return json.loads(bytes(v ^ mask[i%4] for i,v in enumerate(data)))
        def send(obj):
            data = json.dumps(obj).encode()
            header = bytes([129,len(data)]) if len(data) < 126 else b'\\x81\\x7e' + struct.pack('!H',len(data))
            conn.sendall(header+data)
        headers = b''
        while b'\\r\\n\\r\\n' not in headers: headers += conn.recv(4096)
        key = next(line.split(b':',1)[1].strip() for line in headers.split(b'\\r\\n') if line.lower().startswith(b'sec-websocket-key:'))
        accept = base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
        conn.sendall(b'HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: '+accept+b'\\r\\n\\r\\n')
        with open("\(record.path)",'w') as record:
            first = receive(); record.write(first['method']+'\\n'); record.flush()
            assert 'item/agentMessage/delta' in first['params']['capabilities']['optOutNotificationMethods']
            send({'id':first['id'],'result':{'userAgent':'synthetic'}})
            second = receive(); record.write(second['method']+'\\n'); record.flush()
            send({'method':'thread/settings/updated','params':{'threadId':'\(id)','threadSettings':{'serviceTier':'ultrafast','summary':'synthetic ignored'}}})
            while conn.recv(4096): pass
        conn.close(); server.close()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", scriptURL.path]; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let ready = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: socket.path) && ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(20)) }
        let store = SpeedMetadataStore(socket: socket)
        defer { store.stop() }
        store.workingSessions([ActivitySignal.hash(id)]); store.setEnabled(true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.tier == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.connected && store.tier == .ultrafast)
        #expect(try String(contentsOf: record, encoding: .utf8) == "initialize\ninitialized\n")
        store.setEnabled(false); #expect(!store.connected && store.tier == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_TEST_SPEED_DAEMON"] == "1"))
    func existingRealDaemonHandshakeWithoutThreadOrAccountRequests() async throws {
        let store = SpeedMetadataStore()
        defer { store.stop() }
        store.setEnabled(true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.connected && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.connected, "Metadata connection: \(store.failureReason ?? "unknown")")
        #expect(store.tier == nil) // No working session is invented to test this connection.
    }
}
