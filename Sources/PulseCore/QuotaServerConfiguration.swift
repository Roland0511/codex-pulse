import Foundation

/// 固定本地模型目录，避免只读 RPC 的服务启动仍刷新主客户端的模型缓存。
/// 保留 CODEX_HOME 的官方认证兼容性；不读取、复制或改写认证文件。
// 配置在主 actor 创建/加锁，交接给唯一的子进程回收闭包后不再使用。
struct QuotaServerConfiguration: @unchecked Sendable {
    let directory: URL
    let sqliteDirectory: URL
    private let lock = InstanceLock()
    let arguments: [String]

    init(executable: URL, environment: [String: String], stateRoot: URL? = nil) throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: environment["CODEX_HOME"] ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        // 独立 CLI 安装不共享数据库格式；同一安装升级交由官方 SQLite 迁移处理。
        let key = QuotaClient.digest(home.resolvingSymlinksInPath().path + "\n" + executable.resolvingSymlinksInPath().path)
        let requested = stateRoot ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexPulse/QuotaState/v1")
        let root = requested.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(requested.lastPathComponent)
        try Self.privateDirectory(root)
        sqliteDirectory = root.appendingPathComponent(key, isDirectory: true)
        try Self.privateDirectory(sqliteDirectory)
        guard let source = Bundle.module.url(forResource: "QuotaModelCatalog", withExtension: "json") else {
            throw QuotaError.serviceUnavailable
        }
        let directory = fm.temporaryDirectory.appendingPathComponent("codex-pulse-quota-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let catalog = directory.appendingPathComponent("models.json")
            try fm.copyItem(at: source, to: catalog)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalog.path)
            self.directory = directory
            // 不支持这些设置的版本必须失败；不能悄悄退回未保护的 app-server。
            arguments = try ["app-server", "--listen", "stdio://", "--strict-config",
                         "-c", "analytics.enabled=false",
                         "-c", "model_catalog_json=" + Self.tomlString(catalog.path),
                         "-c", "sqlite_home=" + Self.tomlString(sqliteDirectory.path),
                         "-c", "log_dir=" + Self.tomlString(directory.appendingPathComponent("log").path)]
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw QuotaError.serviceUnavailable
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// 锁一直持有到子进程退出；应用和诊断脚本不能同时迁移或回填同一数据库。
    func acquire() throws -> Bool { try lock.acquire(at: sqliteDirectory.appendingPathComponent("runtime.lock")) }

    /// TOML basic string 和 JSON 字符串共用此处所需的路径转义。
    private static func tomlString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        // JSON 的可选 \/ 转义不属于 TOML，不能用于 -c 的路径字符串。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        lock.release()
    }
}
