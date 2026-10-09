import Foundation
import Testing
@testable import PulseCore

@Suite("全局单实例") struct InstanceLockTests {
    @Test func competingOwnersAndCrashRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("instance.lock")
        let first = InstanceLock(), second = InstanceLock()
        #expect(try first.acquire(at: file))
        #expect(try first.acquire(at: file))
        #expect(try !second.acquire(at: file))
        first.release(); #expect(try second.acquire(at: file))
        second.release(); #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try first.acquire(at: file)); first.release()
    }
}
