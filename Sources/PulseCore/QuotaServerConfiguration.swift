import Foundation

/// 固定本地模型目录，避免只读 RPC 的服务启动仍刷新主客户端的模型缓存。
/// 保留 CODEX_HOME 的官方认证兼容性；不读取、复制或改写认证文件。
struct QuotaServerConfiguration {
    let directory: URL
    let arguments: [String]

    init() throws {
        let fm = FileManager.default
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
                         "-c", "sqlite_home=" + Self.tomlString(directory.path),
                         "-c", "log_dir=" + Self.tomlString(directory.appendingPathComponent("log").path)]
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// TOML basic string 和 JSON 字符串共用此处所需的路径转义。
    private static func tomlString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        // JSON 的可选 \/ 转义不属于 TOML，不能用于 -c 的路径字符串。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
