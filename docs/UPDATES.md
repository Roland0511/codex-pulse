# 应用更新

2026-10-13 随 [v0.2.0 / build 6](https://github.com/Roland0511/codex-pulse/releases/tag/v0.2.0) 正式发布，PR #5 已合并。本机已升级。实现采用固定版本 Sparkle 2.10.0，保留其标准安装器和错误恢复。

## 使用方式

菜单或设置中的「检查更新…」可手动查询新版。设置显示当前版本，并提供两个开关：

- 自动检查更新：开启后每天检查一次；默认关闭。关闭也停止未来的自动下载。
- 自动下载并安装更新：开启时同时开启检查；默认关闭。后台下载完成后退出应用时安装，设置出现「安装并重新启动」可立即完成。

后台安装不会强制中断正在使用的应用。需要系统授权时，Sparkle 会显示系统提示，不绕过权限。失败、取消或没有更新均由 Sparkle 标准界面反馈；重复点击检查时不会创建重复会话。开关保存在 Sparkle 自己的用户偏好中，启动不会覆盖用户选择。

0.1.3 及之前没有更新器，需要手动安装此版一次。后续版本由更新清单提供，不依赖更新应用源码或开发工具。原有 hooks、额度缓存策略、账户及偏好不由更新器修改。

## 信任与隐私

- 唯一发布源为本仓库 GitHub Releases，`Resources/Updates.json` 固定 HTTPS 清单 URL 和公开 Ed25519 验签密钥。
- 完整 ZIP 先经过 Ed25519 验证再解压；清单本身也必须验签，不为签名失败设置过期绕过。包内应用另外使用 Developer ID 签名并进行 Apple 公证。
- 私钥仅由 Sparkle 的 `generate_keys` / `sign_update` 从 macOS 钥匙串使用，不导出、不写入仓库、命令参数或日志。公钥可以公开。钥匙串账户名 `dev.roland.codex-pulse` 只标识密钥项目。
- 不读取或上报额度、身份、聊天、hooks 或认证文件。不启用 Sparkle 系统概况统计。正常更新请求会向 GitHub 提供网络连接和应用版本等协议元数据。
- 标准对话框由 Sparkle 提供，跟随系统语言；菜单、设置及状态文案随 Pulse 的中英语言选择。

## 可重复发布

1. 更新版本与 build；提交源码并完成 CI。
2. 按 `DISTRIBUTION.md` 执行 `scripts/package_release.py`：双架构构建，签名 Sparkle 的 Autoupdate、Updater.app、framework、Pulse helper 和应用，公证应用与 DMG。
3. 同一流程用 `scripts/update_feed.py` 对最终 ZIP 签名，生成并签名 `appcast.xml`，验证两份签名。清单中的机器版本使用递增 build，不以显示版本代替。
4. 校验值覆盖 DMG、ZIP 与已签名清单。创建 GitHub draft release，上传这三份文件及 SHA256SUMS.txt；独立验证后再公开。清单经签名后不能手工修改。
5. 匿名下载所有附件，核对字节、签名、版本、架构与源码提交；新版本和旧清单都应保留可恢复的证据。

SwiftPM 固定 Sparkle 版本及二进制校验值，`Package.resolved` 随源码提交。应用不使用 App Sandbox，因此不包含 Sparkle 的可选 XPC Services；保留 Autoupdate 和 Updater.app，所有嵌套可执行文件从内到外分别签名，不以 `codesign --deep` 代替签名流程。

参考：[Sparkle 设置](https://sparkle-project.org/documentation/programmatic-setup/)、[配置项](https://sparkle-project.org/documentation/customization/)、[发布与签名](https://sparkle-project.org/documentation/publishing/)、[嵌套签名](https://sparkle-project.org/documentation/sandboxing/)。

## 当前技术验证

- 更新开关联动、用户偏好保留、忙碌请求去重、演示 / 未配置包不启动更新器由 `UpdaterTests` 覆盖。
- 更新 XML 的 build / 显示版本分离、HTTPS 下载地址、文本转义、非法路径 / 签名 / 元数据拒绝由 Python 回归覆盖。
- 真实 Sparkle `sign_update` 验证有效归档 / feed 并拒绝篡改内容；测试未导出私钥。
- 原生开发候选已验证菜单入口、暂缺 feed 的错误提示及关闭恢复、中英文设置布局、开启自动安装联动开启检查、关闭检查联动关闭下载。签名后的真实升级已完成，见下方记录。


## 正式链路验收

- 84 项 Swift 测试、13 项 Python 测试通过，另 5 项原有真实 CLI 用例按默认配置跳过。Swift 6.1 的绑定代码生成崩溃已通过显式闭包修正，CI 重跑通过；不将首次失败记为成功。
- 正式包来自干净源码 `e592769`，与合并提交 `75973cb` 的源码树一致；应用及 DMG 均为 Apple Accepted，签名、票据、Gatekeeper、ZIP / DMG 内应用独立核验通过。Sparkle helpers 也逐个核验，feed 和 ZIP 数字签名通过。
- 发布前先创建草稿，四个附件大小和摘要匹配后公开。所有正式附件均匿名下载并逐字节核对；匿名 API 的一次 403 不计作通过，改用已核对的发行元数据及直接匿名资产下载完成验证。
- 使用同一修复源码的已签名、公证的独立测试包（显示版本 0.1.99 / build 5，仅用于本机验收，未公开发布）测试真实旧→新流程；0.1.3 本身不含更新器，不能以它代替升级测试包。
- 手动链路：识别正式 feed 中的 0.2.0 → 下载 → 安装并重启；测试目录实际变为 build 6，进程更换，二进制与正式发行包一致，额度重新读取成功。
- 自动链路：在独立测试条件下清除 Sparkle 上次检查时间并启用自动选项，未点击手动检查 / 下载；观察到设置提示「版本 0.2.0 已下载，等待安装」，退出应用后自动替换为 build 6，无需点击安装。二进制与正式发行包一致。
- 本机最终 `/Applications/Codex Pulse.app` 由已核验的公开 ZIP 安装，检查显示已是最新版，自动选项已开启。原有语言、外观、快捷键、位置和固定选择已恢复，hooks 未改写；旧版留在 `local-data/updates-backup/` 可回退。
- 原生检查覆盖中文 / English、浅色 / 深色、错误关闭恢复、版本发现、安装、自动就绪和无更新状态；不扩展为多屏、完整动效或真实休眠验证。
