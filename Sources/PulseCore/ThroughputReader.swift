import Foundation
import Darwin

/// Serialized, bounded local reader. Only files whose filename hashes match trusted active sessions
/// are opened. No directory-wide content search, transcript decoding, inference, or network access.
public actor ThroughputReader {
    public struct Result: Sendable {
        public var samples: [String: ThroughputSample] = [:]
        public var unavailable: Set<String> = []
        public init() {}
    }
    private struct Cursor {
        var device: Int32 = 0
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var prefix = Data()
        var checkpoint = Data()
        var tail = Data()
        var skippingLine = false
        var tracker = ThroughputTracker()
    }
    private let root: URL
    private var paths: [String: URL] = [:]
    private var cursors: [String: Cursor] = [:]
    private var lastIndex = Date.distantPast
    public init(root: URL) { self.root = root }
    public func reset() { cursors = [:]; paths = [:]; lastIndex = .distantPast }
    public func read(sessions: Set<String>, now: Date = Date()) -> Result {
        cursors = cursors.filter { sessions.contains($0.key) }
        paths = paths.filter { sessions.contains($0.key) }
        if sessions.isEmpty { return Result() }
        if now.timeIntervalSince(lastIndex) >= 10 {
            index(sessions); lastIndex = now
        }
        var result = Result()
        for session in sessions {
            guard let path = paths[session] else { result.unavailable.insert(session); continue }
            do {
                var cursor = cursors[session] ?? Cursor()
                try read(path, session: session, cursor: &cursor)
                cursors[session] = cursor
                if let sample = cursor.tracker.sample { result.samples[session] = sample }
            } catch {
                cursors.removeValue(forKey: session); paths.removeValue(forKey: session)
                result.unavailable.insert(session)
            }
        }
        return result
    }
    private func index(_ sessions: Set<String>) {
        let fm = FileManager.default
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                          options: [.skipsHiddenFiles]) else { return }
        var matches: [String: [URL]] = [:], count = 0
        for case let url as URL in iterator {
            count += 1
            if count > 40_000 { paths = [:]; return }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values?.isDirectory != true, url.pathExtension == "jsonl" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("rollout-"), name.count >= 36 else { continue }
            let id = String(name.suffix(36))
            guard UUID(uuidString: id) != nil else { continue }
            let hash = ActivitySignal.hash(id)
            if sessions.contains(hash) { matches[hash, default: []].append(url) }
        }
        // Ambiguous matching paths never silently select the newest unrelated record.
        paths = matches.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }
    private func read(_ path: URL, session: String, cursor: inout Cursor) throws {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ReadError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_size >= 0 else { throw ReadError.unavailable }
        let size = UInt64(info.st_size)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        // Detect rewrite/truncate-and-regrow without retaining a raw prefix. Prefix is hashed.
        let prefix = ActivitySignal.hash((try handle.read(upToCount: Int(min(128, size))) ?? Data()).base64EncodedString())
        let digest = Data(prefix.utf8)
        var checkpointChanged = false
        if cursor.offset > 0, cursor.offset <= size, !cursor.checkpoint.isEmpty {
            try handle.seek(toOffset: cursor.offset > 128 ? cursor.offset - 128 : 0)
            let bytes = try handle.read(upToCount: Int(min(128, cursor.offset))) ?? Data()
            checkpointChanged = Data(ActivitySignal.hash(bytes.base64EncodedString()).utf8) != cursor.checkpoint
        }
        if cursor.inode != info.st_ino || cursor.device != info.st_dev || size < cursor.offset || checkpointChanged ||
            (cursor.offset >= 128 && cursor.prefix != digest) {
            cursor = Cursor(); cursor.inode = info.st_ino; cursor.device = info.st_dev
            cursor.offset = size > 4_194_304 ? size - 4_194_304 : 0
            cursor.skippingLine = cursor.offset > 0
        }
        cursor.prefix = digest
        try handle.seek(toOffset: cursor.offset)
        let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
        cursor.offset += UInt64(bytes.count)
        if cursor.offset > 0 {
            try handle.seek(toOffset: cursor.offset > 128 ? cursor.offset - 128 : 0)
            let checkpoint = try handle.read(upToCount: Int(min(128, cursor.offset))) ?? Data()
            cursor.checkpoint = Data(ActivitySignal.hash(checkpoint.base64EncodedString()).utf8)
        }
        cursor.tail.append(bytes)
        var start = cursor.tail.startIndex
        while let end = cursor.tail[start...].firstIndex(of: 10) {
            if !cursor.skippingLine {
                let line = cursor.tail[start..<end]
                if let event = try? ThroughputEvent.read(Data(line)) { cursor.tracker.receive(event, session: session) }
                else { cursor.tracker.reset() }
            }
            cursor.skippingLine = false
            start = cursor.tail.index(after: end)
        }
        if start > cursor.tail.startIndex { cursor.tail = Data(cursor.tail[start...]) }
        if cursor.tail.count > 2_097_152 {
            cursor.tail = Data(); cursor.skippingLine = true; cursor.tracker.reset()
        }
    }
    private enum ReadError: Error { case unavailable }
}
