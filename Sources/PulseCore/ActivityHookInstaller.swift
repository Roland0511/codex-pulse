import Darwin
import CoreFoundation
import Foundation
import Security

/// 原生发布包自带安装器，不依赖 Python、仓库或终端。
@MainActor public final class ActivityHookInstaller {
    public let hooksURL: URL
    public let support: URL
    public let source: URL
    public var helper: URL { support.appendingPathComponent("PulseActivityHook") }
    private let verify: @MainActor (URL) throws -> Void
    public init(hooksURL: URL, support: URL, source: URL, verify: @escaping @MainActor (URL) throws -> Void = ActivityHookInstaller.verifySignature) {
        self.hooksURL = hooksURL; self.support = support; self.source = source; self.verify = verify
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public var commands: Set<String> { Set(ActivityEvent.allCases.map { Self.shellQuote(helper.path) + " --event " + $0.rawValue }) }
    public var definition: [String: Any] {
        ["description": "Codex Pulse 只读工作状态：不读取聊天记录，不输出或改变会话上下文。",
         "hooks": Dictionary(uniqueKeysWithValues: ActivityEvent.allCases.map { event in
            (event.rawValue, [["hooks": [["type": "command", "command": Self.shellQuote(helper.path) + " --event " + event.rawValue,
                                         "async": true, "timeout": 2]]]])
         })]
    }
    public var reviewText: String {
        (try? JSONSerialization.data(withJSONObject: definition, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private func owned(_ handler: [String: Any]) -> Bool {
        handler["type"] as? String == "command" && (handler["command"] as? String).map(commands.contains) == true
    }
    private func root(_ data: Data?) throws -> [String: Any] {
        guard let data else { return ["description": definition["description"]!] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }
    public func merging(_ root: [String: Any], install: Bool) throws -> [String: Any] {
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var next = root, hooks: [String: Any] = [:], removed = false
        for (event, value) in root["hooks"] as? [String: Any] ?? [:] {
            guard let groups = value as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            var kept: [[String: Any]] = []
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                let remaining = handlers.filter { !owned($0) }
                removed = removed || remaining.count != handlers.count
                if !remaining.isEmpty || handlers.isEmpty { var copy = group; copy["hooks"] = remaining; kept.append(copy) }
            }
            if !kept.isEmpty { hooks[event] = kept }
        }
        if install, let added = definition["hooks"] as? [String: [[String: Any]]] {
            for (event, groups) in added { hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + groups }
        }
        if !install && !removed { return root }
        next["hooks"] = hooks; return next
    }
    public func isInstalled() throws -> Bool {
        let root = try root(readCurrent())
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        var found: Set<String> = []
        for (event, groups) in hooks {
            guard let groups = groups as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                for handler in handlers where owned(handler) {
                    let command = handler["command"] as! String
                    guard command == Self.shellQuote(helper.path) + " --event " + event,
                          found.insert(command).inserted, group["matcher"] == nil,
                          let async = handler["async"] as? NSNumber, CFGetTypeID(async) == CFBooleanGetTypeID(), async.boolValue,
                          let timeout = handler["timeout"] as? NSNumber, CFGetTypeID(timeout) != CFBooleanGetTypeID(), timeout.doubleValue == 2 else { return false }
                }
            }
        }
        guard found == commands, FileManager.default.isExecutableFile(atPath: helper.path) else { return false }
        try verify(helper); return true
    }
    private func readCurrent() throws -> Data? {
        let fd = open(hooksURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadNoPermission) }
        try HookJSONValidation.uniqueKeys(in: file); try file.seek(toOffset: 0)
        return try file.readToEnd()
    }
    private func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pulse-stage-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlink(temporary.path) }
        try file.write(contentsOf: data)
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    public func change(install: Bool) throws {
        try ActivitySocket.privateDirectory(support)
        try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(hooksURL.deletingLastPathComponent().appendingPathComponent(".pulse-hooks.lock").path,
                      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
        let before = try readCurrent(), original = try root(before), next = try merging(original, install: install)
        if !install, NSDictionary(dictionary: next).isEqual(to: original) { return }
        if install { try verify(source) }
        let backups = support.appendingPathComponent("hook-backups")
        try ActivitySocket.privateDirectory(backups)
        let identifier = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        try write(before ?? Data("hooks.json did not exist before installation.\n".utf8),
                  to: backups.appendingPathComponent(identifier + (before == nil ? ".absent" : ".json")))
        guard try readCurrent() == before else { throw CocoaError(.fileWriteUnknown) }
        if install {
            var info = stat()
            if lstat(helper.path, &info) == 0 {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileWriteNoPermission) }
                try write(Data(contentsOf: helper), to: backups.appendingPathComponent(identifier + ".helper"), mode: 0o700)
            }
            try write(Data(contentsOf: source), to: helper, mode: 0o700)
        }
        guard try readCurrent() == before else { throw CocoaError(.fileWriteUnknown) }
        try write(JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys]), to: hooksURL)
    }
    public static func verifySignature(_ url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw CocoaError(.fileReadCorruptFile) }
    }
}
