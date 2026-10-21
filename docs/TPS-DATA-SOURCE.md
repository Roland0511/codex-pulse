# TPS 数据来源核实（2026-10-22）

补充结论：**存在可行数据来源：本地 rollout 中的官方逐响应输出 token 计数，以及模型条目的毫秒级起止时间。GitHub 已有多种实现，本机本会话也确认存在可配对的计数与时间字段。** 可以据此实现随模型响应完成而更新的 TPS；它是条目时间推导的模型输出速率，不能宣称为逐 token 流式瞬时速度或服务器内部纯解码基准。

上一轮仅检查 App Server v2 通知，遗漏了本地记录中的计时字段，研究范围不足。“这次被动连接没收到数据”只能描述该连接，不能推导为 TPS 无法实现。原始初查证据保留在下方，结论由本节补充更正。该调研阶段没有安装第三方工具。用户随后授权按 codex-statusbar 路线实施，当前已用独立 Swift 实现接入；布局和状态契约见 `DESIGN.md`，本轮验证见 `VERIFICATION.md`。

## GitHub 实现对比

以下已读取计算代码，而非仅按项目标题判断。引用固定到本轮取得的提交。

| 项目 | 已核对的数据来源和口径 | 对 Pulse 的价值 |
| --- | --- | --- |
| [dongyue-19/codex-statusbar](https://github.com/dongyue-19/codex-statusbar/blob/17f0ddd25512b9a823b56a37da325d36ca53971f/src/CodexStatusbar/TpsTracker.cs#L115) | 官方 `output_tokens`，除以 `Reasoning` / `AgentMessage` 起止时间的区间并集；随响应与条目完成记录更新。支持两种 usage 载体、重启后完整性检查及旧值状态。 | 最接近本次需求。UI 是 Windows，但计数、区间合并和增量读取方法可在 Swift 中实现。MIT；不必引入它的整个界面、进程发现或其它统计。 |
| [alicanselcuk/codex-tps-hook](https://github.com/alicanselcuk/codex-tps-hook/blob/ab8fa038983298f6f42f5ea89c31e35f673cca10/turn-metrics-reader.ps1#L131) | `token_usage_record.usage`、`response_id` 与模型条目计时；分别计算包含请求前等待的 effective TPS 和去掉部分等待的近似 Decode；Stop 时汇总。 | 证明还可从现有完成事件取得计数和时间，并参考按响应去重。不是连续流式读数；不需要为 Pulse 安装 PowerShell、历史归档、成本统计或额外 hooks。 |
| [adenta/codex-tps](https://github.com/adenta/codex-tps/blob/be549617f50409c8c0e15a8a6838520ec12d2bb1/analysis.go#L131) | `token_count.last_token_usage` 与输入 / 生成条目的时间边界，计算每次响应的 effective TPS；包括首 token 等待，明确不是纯解码速度。 | 可参考旧格式兼容与计时口径，属于按会话分析的 Go 工具，不是浮动胶囊的直接数据服务。 |
| [gaofeng21cn/codex-tps](https://github.com/gaofeng21cn/codex-tps/blob/9dd244128338b810e8022fac05f47d391a3f931a/Sources/CodexTPSCore/UsageMetrics.swift#L81) | 最近固定时间窗口里的 token 总量除以 60 / 300 等秒数；另有输入 / 输出分项。 | 原生 Swift 的文件增量采集可参考，但主 `tokensPerSecond` 是包含输入的滚动用量吞吐，不能直接标成模型生成速度。查询时仓库已归档，当前 LICENSE 为 Apache-2.0。 |
| [yuzhe2002/agent-token-speed](https://github.com/yuzhe2002/agent-token-speed/blob/b9c52b6a4fb8b8c60b59dc87e7f4eca8b145119a/bin/token-speed.js#L40) | Codex notify 路径选最新 rollout 的累计 `total_tokens`，在回调时采样做差分；以固定 `codex` key 保存。 | 不能照搬为当前会话的输出 TPS：统计值包含输入，最新文件也可能属于其它会话。它对其它 agent 的实时插件能力不能直接等同于 Codex。 |
| [zakmandhro/codex-model-benchmarks](https://github.com/zakmandhro/codex-model-benchmarks/blob/8b9b111685c1e756fe4334c9c49fef61eee2348a/benchmark.mjs#L177) | 自建临时线程，开启 `experimentalRawEvents`，主动推理，记录文本 delta 到达时间并结合官方 usage 计算 stream / effective 指标。 | 可了解不同速度口径；不是对现有桌面会话的被动监控方案。本轮只读源码，未运行基准、创建线程或启动推理。 |

`codex-statusbar` 的“实时”是按响应完成刷新，不是每个流式 token 到达就刷新。其 EMA 平滑、旧值保留、短窗口和作者自测精度均是该项目的具体选择，不能直接变成本项目的测量保证。其按 token 数值组合做去重的兼容策略也不应照搬：不同响应可能恰好产生相同计数，优先使用响应标识，缺失时交叉核对累计差分。

## 官方字段与本机交叉核对

- 官方 [ItemCompletedEvent 定义](https://github.com/openai/codex/blob/430a16799d90e296fb27b1e94f206023902b7e56/codex-rs/protocol/src/protocol.rs#L2064) 包含 `started_at_ms` 与 `completed_at_ms`；[TokenUsageRecord 定义](https://github.com/openai/codex/blob/430a16799d90e296fb27b1e94f206023902b7e56/codex-rs/protocol/src/protocol.rs#L2393) 包含逐响应 `usage`、`response_id` 及累计量。它们比前轮只看的 App Server v2 通知更接近需求。
- 官方 [rollout 保存策略](https://github.com/openai/codex/blob/430a16799d90e296fb27b1e94f206023902b7e56/codex-rs/rollout/src/policy.rs#L128) 对 `ItemCompleted`、`TokenCount` 和 `TokenUsageRecord` 有持久化规则。旧格式和不同 history mode 的记录覆盖并不完全相同，不能把“某个字段可能存在”当作所有版本保证。
- 本机只定位**当前会话**对应的一个 rollout，读取范围上限 8 MiB。使用独立路径白名单解析器，仅保留类型、关联标识、时间和 token 数；消息、推理正文、工具参数与结果按字节跳过，不构造正文对象。
- 当前会话确认有官方 `token_usage_record`、模型 `Reasoning` / `AgentMessage` 的合法起止时间，以及包含本轮起点、可配对使用量和模型时间的样本；在检查到的合格记录中，`reasoning_output_tokens <= output_tokens`。未输出或保存原始会话 / 响应标识、聊天正文或原始行。
- 自编投影与区间并集合成检查通过，覆盖正文丢弃、重叠合并、嵌套合并、分离窗口不跨工具空档、空窗口。它们验证本次研究助手的基本处理逻辑，不能替代未来产品采集器的测试。
- 第三方源码快照、提交清单、只读探测脚本和脱敏字段检查留在 Git 忽略的 `private-evidence/tps-research-20261022/`。本轮没有安装 / 执行第三方项目、开启网络监听、改写 Codex 配置 / hooks 或触发推理。

## 推荐给 Pulse 的接入方案

采用“**官方输出计数 + 本地模型条目计时 + 增量读取**”路线。UI 保留用户已确认的横向并排：开启 TPS 时 104 × 36 pt，关闭恢复 54 × 36 pt，展开详情单独显示速率；详情或悬停明确标注“逐响应更新”。

可采用的派生口径是：`输出 token 数 / 模型输出条目区间并集秒数`。只在计数与对应模型阶段完整匹配时发布；不直接用整轮耗时。`output_tokens` 已含推理 token，不再加一次 `reasoning_output_tokens`；是否展示可见输出的另一口径是产品选择，不混用。工具调用参数的生成是否被条目窗口完整覆盖、极短窗口和事件配对仍需专门验证，不能把该派生口径宣传为绝对精确的纯解码测量。

实现时应遵守：

1. 用现有可信工作状态关联已知会话；可以将 rollout 文件名里的标识做同样的内存哈希匹配，只打开匹配文件，避免“最新修改文件就是当前会话”的假设。多路归属不明确时显示多路 / 未知，不随意相加。
2. 按字节偏移读取新增记录；本次实现选择活动单会话每秒有界检查，兼顾响应刷新、替换检查及保留值超时，初始恢复设有界尾读预算；缺少本轮起点或计时不完整时等下一份合格样本，不为补数据无限扫描历史。
3. 仅投影白名单元数据，正文不解析、不缓存、不上报；关联标识只在内存中存在。无需 CDP 注入、代理请求、认证令牌或新增服务聚合。
4. 以响应标识去重；正确处理 `token_usage_record` 与 `token_count` 的重复载体、计数重置、截断 / 替换、旧版本缺字段，以及文件最后半行。
5. 没有首个样本时显示等待，数据不可用时显示 `—`；空闲、工具阶段沿用值和最近一次已完成值均明确标记，不把保留值显示成新的实时样本。减少动态效果继续生效。

以上为接入依据；实施选择在 `DESIGN.md` 中细化，**不再以“没有直接 TPS API”作为功能无法实现的理由**。

## 前轮初查记录：独立 App Server 路线

- OpenAI 官方 [App Server 文档](https://learn.chatgpt.com/docs/app-server) 列出了 `thread/tokenUsage/updated`、`turn/started` 和 `turn/completed`，并支持初始化时按方法名屏蔽通知。文档未在这些通知中定义实时 TPS 或纯模型生成时长。
- 本机独立 CLI / 已运行 daemon 为 `0.163.0`，桌面内置 CLI 为 `0.163.0-alpha.10.2`。分别用各自的 `app-server generate-json-schema --experimental --out <本机证据目录>` 导出协议，无推理任务。
- 两份协议的 `ThreadTokenUsageUpdatedNotification` 都包含 `threadId`、`turnId`、`tokenUsage.last/total`；`TokenUsageBreakdown` 包含 `inputTokens`、`cachedInputTokens`、`cacheWriteInputTokens`、`outputTokens`、`reasoningOutputTokens`、`totalTokens`，没有对应的生成时长、逐 token 时间戳或 TPS 字段。
- 两份协议的 `Turn` 包含可空的 `startedAt`、`completedAt`、`durationMs`；`durationMs` 明确定义为整轮开始到完成的耗时，不能等同于纯模型生成时间。
- 对已运行的官方 Unix WebSocket 做 45.038 秒被动观察：仅发送 `initialize` 和 `initialized`，初始化成功；按协议的方法列表屏蔽其它通知，仅允许上述三种元数据通知。该连接在观察期间未收到这些通知。没有订阅 / 恢复会话，也没有创建线程、启动推理或读取历史。
- 观察器以路径白名单投影数值字段，其它载荷按字节跳过；未保存原始载荷、会话标识、账户或聊天内容。协议导出、观察脚本及脱敏结果仅在 Git 忽略的 `private-evidence/tps-source-20261022/` 中。

没有事件的观察结果只说明这一次被动连接没有取得样本，**不能证明其它客户端或本地记录无法提供这些信息**。这条连接当时未验证可用，但上面的本地计时与 token 记录路线已确认存在。

### 这条连接的局限

1. token 用量本身没有提供逐 token 或纯生成阶段的时间信息；相邻用量通知的时间差也可能包含工具调用、等待和其它工作。
2. 用输出 token 数除以整轮时间得到的是整轮平均吞吐，不能标为设计中的实时「生成速度」。
3. 已有 `standard / fast / ultrafast` 是服务档位，只用于工作动效，不代表实测速率。
4. 不以正文长度估算 token，不扫描或解析聊天正文，不代理请求，不读取认证令牌，也不为了取得样本启动推理任务。此前将“不扫描聊天日志”笼统扩大为不检查其中独立的计数 / 时间元数据，不应成为忽略可行来源的理由。
