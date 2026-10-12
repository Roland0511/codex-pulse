# 额度连接与共享模型缓存保护

2026-10-12，Asia/Shanghai；对应 [issue #1](https://github.com/Roland0511/codex-pulse/issues/1)。修复已随 [v0.1.2 / build 4](https://github.com/Roland0511/codex-pulse/releases/tag/v0.1.2) 发布；已有 v0.1.1 安装包仍保留旧实现，需升级应用。

## 为什么用 App Server

独立应用使用官方公开的 `account/read` 和 `account/rateLimits/read` 协议，让官方 CLI 负责既有登录状态及认证兼容性；Pulse 不解析、复制或改写令牌，也不使用浏览器 Cookie。聊天内可用的额度工具不是独立 macOS 应用可以调用的接口。

查询额度不需要模型目录，也不需要启动推理任务。旧实现只限制了业务 RPC，没有限制 App Server 初始化期间的后台模型刷新；因此「RPC 只读」不能推导为「进程不会改写本地状态」。issue 已观察到 `codex_pulse` 参与共享 `models_cache.json` 的改写；这不证明它是所有客户端模型能力变化的唯一来源。

本机两种 CLI 都支持 `app-server proxy` 连接现有控制套接字，但本次 `daemon version` 检查确认默认控制套接字不存在。只改成 proxy 会让这种桌面登录环境失去额度读取能力。此修复保留按需 stdio helper，不启动 / 重启共享 daemon，不接管桌面进程。未来如复用已有服务，需要另行验证连接和通知隔离，不能把版本支持等同于已存在可连接的服务。

## 修复行为

- 每次启动给子进程传入 `model_catalog_json`，指向随包提供的固定本地目录，从而选择不进行远程目录刷新和共享缓存写入的静态目录路径。
- CLI 要求目录至少包含一个模型。文件只有一个隐藏、禁用 shell 的 `codex-pulse-quota-only` 占位条目，不表示真实模型或账户权益；Pulse 的请求白名单仍拒绝线程、推理和模型查询。
- 临时目录权限为 `0700`，模型文件为 `0600`；`sqlite_home`、`CODEX_SQLITE_HOME` 和 `log_dir` 指向该子进程的独立临时位置。子进程回收后删除目录；启动失败也清理。崩溃 / 断电后的临时文件由系统临时目录生命周期兜底，不宣称这等于完整的文件系统沙盒。
- 继承原有 `CODEX_HOME`，保持官方认证兼容性。没有创建替代认证 home、复制认证文件或改动主客户端配置。
- 使用 `--strict-config`；不支持保护设置或目录损坏时停止读取，绝不重试未经保护的服务启动。主配置有当前 CLI 不识别的字段时也可能拒绝启动，此时应核对 CLI 版本与配置兼容性。
- 正常读取保留前后账户身份核对；可选 `hooks/list` 信任检查使用同一受保护启动路径。自动轮询、手动刷新、唤醒及重启均经过 `QuotaClient.launch()`。
- `scripts/probe.py` 采用相同目录文件和启动保护，避免诊断脚本重新触发问题。构建脚本将 SwiftPM 资源包一同复制进 `.app`。

这项保护针对模型目录刷新及指定运行时文件。官方 CLI 仍负责认证生命周期；不把整条进程描述为不会产生任何本地写入。

## 技术验证

核实工具链：macOS 26.6.2、Swift 6.4、Xcode 27.0；CLI 为桌面内置 `0.162.0-alpha.17.2` 和全局 `0.162.1`。

| 验证 | 证据与边界 |
| --- | --- |
| Swift 自动回归 | 73 项通过；包括重复读取复用、子进程重启、hooks 检查、共享合成缓存不变、独立目录回收及拒绝不支持的配置后不降级 |
| Swift / 真实 CLI 交叉检查 | 另一个显式启用的用例通过两种 CLI 的合成后端检查，验证实际 Swift 启动参数及 TOML 路径转义；普通 `swift test` 跳过此用例 |
| 真实 CLI / 合成账户 | 两种 CLI 均通过；独立临时 home、合成 JWT、本机 HTTPS 夹具及临时 CA，不读取真实凭据、不安装系统信任 |
| 负向对照 | 在上述合成 home 中移除固定目录参数，观察到 `/models` 请求；受保护启动的模型请求为零 |
| 连续 / 并发 | 每种 CLI 进行 3 次独立启动和 2 个同时查询；额度读取成功，合成主缓存字节、修改时间及 inode 不变 |
| 无效目录 | 无效空目录在模型网络请求 / 缓存写入前失败；没有移除保护后重试 |
| 真实登录只读查询 | 桌面内置 CLI 成功读取额度，保留 10 秒观察期；真实共享缓存字节、修改时间及 inode 不变，子进程回收；只保存脱敏判断在 Git 忽略目录 |

完整 Python 回归 13 项通过（包含上述真实 Swift 客户端交叉检查）；未设置 `PULSE_TEST_CODEX` 时其中 4 项实装 CLI 回归明确跳过。随后正式 `0.1.2 / build 4` 通用架构应用及 DMG 均获 Apple 公证 Accepted，签名、票据、Gatekeeper、ZIP 解压及 DMG 挂载副本独立复核通过；已公开发布，未替换本机已安装应用。详见 [分发记录](DISTRIBUTION.md)。

复验命令：

```sh
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
# 显式选择要验证的官方 CLI；只运行本机合成账户 / HTTPS 夹具。
PULSE_TEST_CODEX=/path/to/codex python3 -m unittest discover -s Tests -p 'test_quota_server.py' -v
```

技术测试不替代真实桌面交互验收。本次没有重新验收拖动、多屏、休眠、Ultrafast 入口或持续真实会话上下文，也没有恢复 / 覆盖用户现有模型缓存。旧缓存被其它客户端改写后的恢复由官方客户端正常刷新处理。

协议参考：[官方 App Server](https://learn.chatgpt.com/docs/app-server)、[配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)；静态目录行为另经本机二进制和合成对照验证。
