import Darwin
import Foundation

/// 同一用户的正式 / 演示 / 不同路径副本共用文件锁，避免重复窗口及菜单栏项。
public final class InstanceLock {
    private var descriptor: Int32 = -1
    public init() {}
    public func acquire(at url: URL) throws -> Bool {
        if descriptor >= 0 { return true }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(fd)
            if code == EWOULDBLOCK { return false }
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = fd
        return true
    }
    public func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1
        // 不删除锁文件，避免新进程锁住不同 inode 形成双实例。
    }
    deinit { release() }
}
