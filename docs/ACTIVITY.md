# 工作状态接入

状态：2026-10-09 用户授权的真实审批等待 / 恢复验收通过，65 项 Swift 回归通过。12 条 hooks 已受信任，真实工作与 Stop 已记录；设置页额度一致、连续 600 秒空闲以及流光范围 / 渐隐 / 水平对齐证据保留。真实审批发现并修复了无 ID 许可与晚到前置事件的关联问题，详见 VERIFICATION.md。

## 取舍和来源

核查 README 中两个参考项目的源代码：

| 项目 / 核查版本 | 相关实现 | 本项目结论 |
| --- | --- | --- |
| [QuotaView](https://github.com/Duoasa/QuotaView/tree/13a74949760a6360b410064928fb246e577e9365) | `CodexLocalRolloutActivityClient` 读取 `task_started` / `task_complete`；`CodexDesktopIPCClient` 跟随完整会话状态；`QuotaViewActivityHook` 通过官方 hooks 输出脱敏事件 | 生命周期事件、并行汇总和有界状态可借鉴；会话文件、完整历史、公开进度及工具内容不进入 Pulse |
| [Codex Monitor](https://github.com/jackiemingnew/codex-monitor-macos/tree/ba07a9fac37e7110e6336fb9ad05b79f41adbc16) | `CodexUsageStore.loadActiveThreadIDs` 聚合日志中的活动 / 完成模式，`sessionLooksActive` 核查会话记录 | 依赖会话文件和日志内容，且有时间窗口推断，不用于 Pulse |

两者均为 MIT 项目，本次只参考架构思路，代码独立编写，没有复制源码。QuotaView 的自动发现无需 hook 安装，依靠上述记录 / 状态流；Pulse 保持既定边界，采用需要用户审阅的 hooks 路径。[官方 hooks 文档](https://learn.chatgpt.com/docs/hooks)支持生命周期事件、后台命令以及逐定义信任审核。

独立额度 App Server 的 `thread/loaded/list` 本机返回空列表，不能观察桌面会话；默认共享控制套接字不存在。没有启动新守护服务、重连用户会话或用文件修改时间 / CPU 猜测工作状态。

## 只保留状态

- helper 从 stdin 流式跳过非白名单 JSON 值，不解码 / 保存提示词、工具参数、工具结果或回复，不打开 `transcript_path`。
- 白名单仅包含 `hook_event_name`、`session_id`、`turn_id`、`agent_id`、`tool_use_id`、`tool_name`；标识和工具类别立即 SHA-256 哈希。跨进程仅发送事件、哈希、时间及 Codex 祖先进程的 PID / 启动时间，不发送工具名称、参数或结果。
- 状态通过当前用户的本机 Unix datagram socket 传递；目录 0700、socket 0600。无 TCP 监听，无认证令牌或 Cookie，无账户修改。
- 不输出 stdout / stderr，不返回许可决定、上下文、继续 / 中断请求。helper 失败或 Pulse 退出时仍退出 0；命令配置为后台执行，超时 2 秒。官方运行时对 `SessionEnd` 强制同步执行，其余事件按后台方式运行。
- 所有状态仅留内存，不持久化事件、原始标识、聊天或队列。`--check` 仅用于显式合成输入验证，不出现在安装定义中。

显式设置 `PULSE_DIAGNOSTICS_FILE` 时，验收进程可写出进程 / 请求计数、工作布尔值、是否收到信号以及最近 64 条事件类型、数量及关联布尔值，用于核对实际生命周期；没有会话或工具标识、哈希、工具名称、额度、身份或正文。产品默认不输出诊断，本机验收文件留在 Git 忽略的 `private-evidence/`。

## 行为

`UserPromptSubmit` / `PreToolUse` 表示工作；`PermissionRequest` 暂停对应会话，关联的 `PostToolUse` 恢复；`Stop` / `Interrupt` / `SessionEnd` 终止相应状态。并行会话及子代理独立汇总，任一已确认会话工作时持续播放。完成墓碑防止后台晚到事件重新点亮旧轮次。工具完成收据防止同一调用的晚到许可事件错误暂停；关联工具的等待 / 完成不因其它调用较新的时间戳而被丢弃。源进程退出、PID 复用或 30 分钟无生命周期证据时停止显示工作；这时状态未知，不能声称任务完成。

本机 `rust-v0.162.0-alpha.2` 的[官方许可输入 schema](https://github.com/openai/codex/blob/rust-v0.162.0-alpha.2/codex-rs/hooks/schema/generated/permission-request.command.input.schema.json)没有 `tool_use_id`，不能要求该字段。无调用 ID 的许可统一保留工具类别等待，直到该类已知调用全部结束；不能把当时唯一候选当作精确关联，因为本次 PreToolUse 可能仍在后台晚到。同轮次 / 同源、未完成的 PreToolUse 允许晚到，已有完成收据和结束墓碑仍阻止旧调用复活。缺少前置信号时，类别匹配的完成事件可以解除等待；其它类别不会解除它。该关联保守，可能延后恢复，不将它称为唯一审批请求的精确识别；本机实际审批已验证等待 / 恢复，但不能据此保证后台事件丢失或全部极端乱序均有精确关联。[官方后台执行说明](https://learn.chatgpt.com/docs/hooks#run-hooks-in-the-background)明确允许调用乱序，并规定会话结束事件同步执行。

工作期间文字为「Codex 工作中」，额度线沿用 2 pt 轨道、1.2 pt 流光；移动与裁切均限制在已填充额度段，与填充共用宽度和数值过渡，不横跨未填充底轨。0 / 未知时只有静态工作文字，没有流光视图。结束后停止；刷新确认的真实额度下降仍可短暂显示「检测到额度消耗」。等待许可、隐藏、睡眠、额度不可用 / 过期时不播放；减少动态效果时保留静态文字。显示胶囊或恢复读取后，仍有效的工作信号可恢复流光。

每圈接近左端时渐隐，完全透明后从右端淡入；透明度曲线按单圈重复，位置复位不会处于可见阶段。保留 3.2 秒 / 三圈，使用参数源中的单圈 12% / 80% / 98% 淡入结束、渐隐开始和透明边界；不恢复应用逐帧更新。

最新水平对齐修正取消尾部光点的纵向摆动，头部 / 尾迹 / 光点共用中线；新包已通过技术验证并运行，真实工作短条完整周期的原生抽查确认中线、填充裁切及渐隐正常，见 `VERIFICATION.md`。

流光采用原生 `CALayer` / `CAKeyframeAnimation`，只在开始、停止、尺寸和颜色变化时配置；应用不逐帧更新共享模型。有限额度下降反馈使用一次到期检查，暂停和快照过期通过状态事件停止；系统减少动态效果直接移除动画视图，没有轮询动画时钟。参考[苹果 Core Animation 原理](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html)。

hooks 覆盖启用这些定义的本地 Codex 运行时；云端 / 未加载定义的旧进程不保证覆盖。Pulse 重启不扫描历史补状态，须等待下一条生命周期事件。hooks 的 `Stop` 是运行时停止阶段，若其它 hook 阻止停止或 goal 随后自动续跑，下一条工作事件恢复状态。不能用缺失信号证明所有会话空闲。

本机自然任务已观察到 Stop 使 working=false，约 9 秒后目标自动续跑的 PreToolUse 使 working=true。连续空闲采样据此中止；这段证据不等于许可等待 / 恢复通过，也不等于全部 Codex 会话持续空闲。

## 性能边界

12 条定义按对应事件触发，每次调用一个短生命周期 helper；不维持 12 个常驻进程。工具执行前后各会触发一次，因此工具调用频率及输入大小会影响累计开销。后台执行仍需要 Codex 生成事件输入、调度进程和传输数据，不能称为零开销；`SessionEnd` 强制同步执行，可能增加会话关闭等待，本项目配置超时 2 秒。[官方后台运行约定](https://learn.chatgpt.com/docs/hooks#run-hooks-in-the-background)还限制每会话最多 8 个后台钩子并行，超出时排队。

2026-10-09 已对安装的 helper 进行合成输入直接调用测量：约 1 KiB / 64 KiB / 1 MiB / 8 MiB 输入的单次中位墙钟耗时分别为 6.305 / 7.507 / 12.599 / 48.941 ms。1 KiB 组出现一次 701.031 ms 最大耗时，原因尚未定位，不能省略该样本或将中位数当作延迟上限。只测量 `--check` 启动、状态提取与输出；没有经过 Codex 的 JSON 生成、shell 调度、socket 接收及动画，也没有启动推理或修改信任。上述数值不代表真实会话总体性能；接入后的工作 / 空闲测量范围及限制见 `VERIFICATION.md`。

信任后的持续工作流光另有 60 秒实测：最终系统图层版本 Pulse 平均 CPU 约 0.050%，自有额度服务约 0.250%，平均总 RSS 108.06 MiB、读取峰值 211.23 MiB。采样仅含 Pulse 及它的后代服务；不包含用户 Codex 启动的 helper、Codex 事件生成、GPU / WindowServer，也不是普通空闲验收。不能把这些值称为整个 Codex 的总开销。

信任后的自然空闲另有连续 600.043 秒 / 580 次观察，全部 working=false / suspended=false：Pulse CPU 估算 0.057%、自有额度服务 0.277%，平均总 RSS 133.20 MiB、峰值 246.23 MiB，同时最多一个自有服务。该记录在本次填充范围修正前完成，包含一次服务末行 CPU / RSS 归零的统计限制，详见 `VERIFICATION.md`；不作为最新包的重复实测或整个 Codex 的性能结论。

## 审阅、安装和撤销

### 已打包应用

默认关闭工作特效。首次启动只在菜单提供「启用工作特效…」入口，不自动写配置，也不弹安装窗口；额度查看可直接使用。

1. 打开 Pulse「设置 → 工作特效」。开启后展示完整 12 条定义、写入路径、保留其它钩子和备份说明；确认后安装。
2. 按「信任步骤」启动官方 Codex CLI，输入 `/hooks`，逐条审阅并信任 Pulse 定义。指引可复制本机 CLI 启动命令、查看完整定义；不代用户执行信任。
3. 回到设置点击「检查连接」。开关表示已安装，旁边明确显示未启用、等待信任、部分缺失 / 禁用、暂无法核对或连接就绪。通过官方只读 `hooks/list` 确认全部 12 条启用且受信任，并确认本机接收器可用，才允许持续流光；不能只信任开始事件就点亮工作状态。
4. 关闭开关立即清除工作状态，只移除 Pulse 的 handlers；其它 hooks、信任记录、备份和 helper 保留。再启用时可重新安装修复。

安装器为 Swift 原生实现，helper 随 `.app` 打包并签名。运行时不需要 Python、仓库或构建工具。安装到稳定的 `~/Library/Application Support/CodexPulse/PulseActivityHook` 路径，因此移动 `.app` 不会让已安装的命令失效。安装器先核查签名和原配置，使用与开发脚本相同的本机锁、私有备份与原子写入；配置有重复键、错误格式或不安全归属时拒绝覆盖。

启动、打开设置和手动检查时核对已安装连接；尚未确认信任时收到合法元数据会触发有限频率的只读核对。等待期间只在内存保留至多 32 条信号，核对后只接纳仍在 15 秒有效期内且源进程仍存活的事件。不扫描历史补状态，不为连接检查启动推理。

### 开发与命令行维护

先构建，再生成待审阅定义：

```sh
python3 scripts/build_app.py
python3 scripts/activity_hooks.py prepare
```

`dist/activity-hooks.json` 只列本项目新增的 12 个事件定义：每条都调用本机 `~/Library/Application Support/CodexPulse/PulseActivityHook --event EVENT`，配置 async / 超时 2 秒；`SessionEnd` 的实际同步行为以上述官方约定为准。prepare 不修改 Codex 配置。helper 已包含在 `.app` 内并单独 ad-hoc 签名。

用户审阅后安装：

```sh
python3 scripts/activity_hooks.py install
```

原生安装器及开发脚本均将 helper 复制到上面的稳定路径，并合并 `$CODEX_HOME/hooks.json`（默认 `~/.codex/hooks.json`）。保留其它 hooks、matcher 和附加字段；备份原配置及旧 helper 到本机 `CodexPulse/hook-backups/`。无效 / 重复 JSON 键、归属异常或检查时发现并发改写则拒绝覆盖。没有更改 `config.toml`、账户、插件或任何信任记录。本机 `codex features list` 已核实 `hooks stable true`，其它环境应先核实功能是否启用。

安装后仍需在 Codex `/hooks` 审阅并信任这些精确命令。[官方要求](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks)：新建或修改的非托管 hooks 在信任前会跳过。不得伪造托管来源、直接改写信任记录或使用跳过审核参数。本次不会为测试创建推理任务，真实覆盖随用户正常会话验证。

撤销只移除 Pulse 的 handlers：

```sh
python3 scripts/activity_hooks.py remove
```

保留其它 hooks、用户信任记录和可恢复的备份 / helper；不直接用旧配置覆盖后来新增的用户设置。备份包含用户原有命令，属于本机私有文件，不能提交 Git。

## 验证边界

`ActivityTests` 验证并发、等待 / 恢复、晚到事件、旧轮次结束、过期与进程消失，及大量合成正文的白名单投影；`ActivityStoreTests` 验证本机 socket、权限拒绝、暂停 / 恢复、信任门槛和退出清理。`OverlayTests` 验证工作状态超过原 3.2 秒仍播放、隐藏 / 恢复、减少动态效果静态提示。原生安装器及 Python 测试验证保留配置、幂等安装、移除、危险配置与无效签名拒绝；信任解析测试验证部分 / 禁用 / 修改的定义不能通过。所有测试输入均为合成数据。

真实安装信任、桌面自然会话的开始 / 暂停 / 恢复 / 结束和异常退出仍须另记证据。合成演示 `working` 可检查持续流光，明确标注演示，不读取账户或真实信号。

本机安装记录：2026-10-09 用户选择「允许安装，我会在 Codex 审阅信任」后执行安装。合并核对 12 个事件各有 1 条本项目 handler；原有 handlers 保留；helper 0700、hooks.json 0600。随后独立官方服务仅调用 initialize / initialized / hooks/list，确认 12 条均启用但未信任；未创建推理任务，未修改信任。脱敏元数据分别保存在 `private-evidence/activity-install.json` 和 `activity-trust.json`。
