import Darwin
import Foundation

public enum ActivitySocket {
    public static var location: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPulse/activity.sock")
    }
    public static func privateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
    }
    public static func address(_ url: URL) throws -> sockaddr_un {
        let bytes: [UInt8] = Array(url.path.utf8) + [0]
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CocoaError(.fileReadInvalidFileName) }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return address
    }
    public static func listen(at url: URL) throws -> Int32 {
        try privateDirectory(url.deletingLastPathComponent())
        var address = try address(url), info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw CocoaError(.fileReadNoPermission) }
            // 调用者必须先持有全局实例锁；此处只清理上次异常退出的自身套接字。
            guard unlink(url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(url.path, 0o600) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(descriptor); unlink(url.path); throw CocoaError(.fileWriteUnknown)
        }
        return descriptor
    }
    public static func send(_ signal: ActivitySignal, to url: URL = location) throws {
        try privateDirectory(url.deletingLastPathComponent())
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let data = try JSONEncoder().encode(signal)
        guard data.count <= 2048 else { throw CocoaError(.fileWriteUnknown) }
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var address = try address(url)
        let count = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                data.withUnsafeBytes { bytes in
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard count == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
}
