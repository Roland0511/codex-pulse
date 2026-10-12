import Foundation
import Testing
@testable import PulseCore

@Suite("额度私有数据库生命周期") struct QuotaServerConfigurationTests {
    @Test func namespacePermissionsLockAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: "/synthetic/codex")
        let first = try QuotaServerConfiguration(executable: executable, environment: ["CODEX_HOME": "/synthetic/a"], stateRoot: root)
        let same = try QuotaServerConfiguration(executable: executable, environment: ["CODEX_HOME": "/synthetic/a"], stateRoot: root)
        let home = try QuotaServerConfiguration(executable: executable, environment: ["CODEX_HOME": "/synthetic/b"], stateRoot: root)
        let cli = try QuotaServerConfiguration(executable: URL(fileURLWithPath: "/synthetic/other"), environment: ["CODEX_HOME": "/synthetic/a"], stateRoot: root)
        defer { first.remove(); same.remove(); home.remove(); cli.remove() }
        #expect(first.sqliteDirectory == same.sqliteDirectory)
        #expect(first.sqliteDirectory != home.sqliteDirectory && first.sqliteDirectory != cli.sqliteDirectory)
        #expect(try first.acquire())
        #expect(try !same.acquire())
        let marker = first.sqliteDirectory.appendingPathComponent("completed-backfill")
        try Data("synthetic".utf8).write(to: marker)
        first.remove()
        #expect(try same.acquire())
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: first.sqliteDirectory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test func symlinkStateRootFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) {
            _ = try QuotaServerConfiguration(executable: URL(fileURLWithPath: "/synthetic/codex"), environment: [:], stateRoot: link)
        }
    }
}
