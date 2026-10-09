import Darwin
import Foundation
import Testing
@testable import PulseCore

@Suite("发布包原生钩子安装", .serialized) @MainActor struct ActivityHookInstallerTests {
    private func fixture(verify: @escaping @MainActor (URL) throws -> Void = { _ in }) throws -> (ActivityHookInstaller, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("packaged-helper")
        try Data("synthetic signed helper".utf8).write(to: source)
        return (ActivityHookInstaller(hooksURL: root.appendingPathComponent("codex/hooks.json"),
            support: root.appendingPathComponent("Pulse Support"), source: source, verify: verify), root)
    }
    private func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
    @Test func installReinstallAndRemovePreserveForeignCommandsAndFields() throws {
        let (installer, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign: [String: Any] = ["description": "original", "extra": ["value": 7], "hooks": [
            "PreToolUse": [["matcher": "synthetic", "groupField": true, "hooks": [["type": "command", "command": "foreign-only", "timeout": 9]]]],
            "Stop": [["hooks": []]], "FutureEvent": [["hooks": [["type": "command", "command": "another-owner"]]]]]]
        try write(foreign, to: installer.hooksURL)
        #expect(try !installer.isInstalled())
        try installer.change(install: true)
        #expect(try installer.isInstalled())
        let first = try Data(contentsOf: installer.hooksURL)
        try installer.change(install: true)
        #expect(try Data(contentsOf: installer.hooksURL) == first)
        #expect((try FileManager.default.attributesOfItem(atPath: installer.helper.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: installer.hooksURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try installer.change(install: false)
        #expect(try !installer.isInstalled())
        let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as! [String: Any]
        #expect(NSDictionary(dictionary: removed).isEqual(to: foreign))
        #expect(FileManager.default.fileExists(atPath: installer.helper.path))
        let backups = installer.support.appendingPathComponent("hook-backups")
        #expect((try FileManager.default.attributesOfItem(atPath: backups.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count >= 3)
    }
    @Test func removalBeforeInstallationDoesNotCreateConfiguration() throws {
        let (installer, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try installer.change(install: false)
        #expect(!FileManager.default.fileExists(atPath: installer.hooksURL.path))
        #expect(!FileManager.default.fileExists(atPath: installer.helper.path))
    }
    @Test(arguments: [#"{"hooks":{},"hooks":{}}"#, #"{"hooks":{"Stop":[{"hooks":[],"hooks":[]}]}}"#, #"{"hooks":["wrong"]}"#, #"{"hooks":{"Stop":[{}]}}"#])
    func invalidOrDuplicateConfigurationIsNeverOverwritten(_ json: String) throws {
        let (installer, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: installer.hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = Data(json.utf8); try before.write(to: installer.hooksURL)
        #expect(throws: (any Error).self) { try installer.change(install: true) }
        #expect(try Data(contentsOf: installer.hooksURL) == before)
        #expect(!FileManager.default.fileExists(atPath: installer.helper.path))
    }
    @Test func unsafeSymlinkOrInvalidSignatureFailsBeforeMutation() throws {
        let (installer, root) = try fixture(verify: { _ in throw CocoaError(.fileReadCorruptFile) })
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["hooks": [:]], to: installer.hooksURL)
        let before = try Data(contentsOf: installer.hooksURL)
        #expect(throws: (any Error).self) { try installer.change(install: true) }
        #expect(try Data(contentsOf: installer.hooksURL) == before)
        let target = root.appendingPathComponent("foreign.json")
        try FileManager.default.moveItem(at: installer.hooksURL, to: target)
        try FileManager.default.createSymbolicLink(at: installer.hooksURL, withDestinationURL: target)
        #expect(throws: (any Error).self) { try installer.change(install: true) }
        #expect(try Data(contentsOf: target) == before)
        #expect(!FileManager.default.fileExists(atPath: installer.helper.path))
    }
    @Test func changedEventOptionsOrMissingHelperNeedRepair() throws {
        let (installer, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try installer.change(install: true)
        var definition = installer.definition
        var hooks = definition["hooks"] as! [String: [[String: Any]]]
        hooks["Stop"]![0]["matcher"] = "changed"
        definition["hooks"] = hooks
        try write(definition, to: installer.hooksURL)
        #expect(try !installer.isInstalled())
        try installer.change(install: true)
        #expect(try installer.isInstalled())
        try FileManager.default.removeItem(at: installer.helper)
        #expect(try !installer.isInstalled())
    }
}

@Suite("只读信任状态") struct HookTrustTests {
    let commands = Set(ActivityEvent.allCases.map { "synthetic --event " + $0.rawValue })
    func response(status: String = "trusted", enabled: Any = true, drop: Bool = false, duplicate: Bool = false) throws -> Data {
        var hooks = commands.sorted().map { ["command": $0, "enabled": enabled, "trustStatus": status] as [String: Any] }
        if drop { hooks.removeLast() }; if duplicate { hooks.append(hooks[0]) }
        hooks.append(["command": "foreign", "enabled": 0, "trustStatus": "unrecognized"])
        return try JSONSerialization.data(withJSONObject: ["data": [["hooks": hooks]]])
    }
    @Test func partialDisabledOrModifiedDefinitionsCannotEnableAnimation() throws {
        #expect(try HookTrustSummary.parse(response(), commands: commands).fullyTrusted)
        for data in [try response(status: "untrusted"), try response(status: "modified"), try response(enabled: false), try response(drop: true)] {
            #expect(try !HookTrustSummary.parse(data, commands: commands).fullyTrusted)
        }
    }
    @Test func numericBooleansDuplicatesAndUnknownTrustFailClosed() throws {
        for data in [try response(enabled: 1), try response(duplicate: true), try response(status: "unknown")] {
            #expect(throws: (any Error).self) { try HookTrustSummary.parse(data, commands: commands) }
        }
    }
}
