# Codex Pulse

一个极简的 macOS 原生 Codex 额度浮动胶囊。

平时只显示剩余额度和重置倒计时；拖到屏幕侧边自动吸附，点击时展开必要信息。动效只响应操作和状态变化，常驻时保持安静。

## 当前状态

- 阶段：v0.1 设计已于 2026-10-08 冻结，尚未实现原生应用。
- 目标平台：macOS 14+，优先在用户实际使用的 Mac 上验证。
- 技术方向：SwiftUI + AppKit（NSPanel），通过本地 Codex App Server 获取额度。
- 项目仅在本地初始化，尚未创建 GitHub 远程仓库。

## 第一版

- 约 180 × 36 pt 的横向胶囊：剩余百分比、重置倒计时、细额度条。
- 自由拖动、左右侧边吸附、位置记忆。
- 点击展开小面板：额度窗口、准确重置时间、可用重置次数、最后更新时间。
- 低额度提醒、异常与过期数据提示、菜单栏入口和隐藏快捷键。
- 克制的吸附、展开、数值更新与重置反馈动效。

第一版不做任务列表、token 图表、模型信息、CPU/内存监控、多账户管理或额度重置操作。

## 已冻结设计

采用「细线胶囊」，参数与行为以 [设计规范](docs/DESIGN.md) 为准。可打开 [交互参考](design/v0.1/thin-capsule.html) 查看。

## 文档

- [v0.1 实施计划](docs/V0.1-PLAN.md)：里程碑、边界、估算及验收标准。
- [设计约定](docs/DESIGN.md)：布局、交互、信息优先级和动效。
- [项目协作约定](AGENTS.md)：开发和验证规则。

## 参考

- [Codex App Server 官方文档](https://learn.chatgpt.com/docs/app-server)
- [QuotaView](https://github.com/Duoasa/QuotaView)
- [Codex Monitor](https://github.com/jackiemingnew/codex-monitor-macos)

上述项目为前期调研参考，当前未复制第三方代码。后续复用代码时核实许可证并保留要求的声明。
