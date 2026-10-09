# macOS 手动分发

状态：2026-10-09 用户已授权提交 / 推送并制作 Developer ID 正式分发包。源码已推送；正式签名仍等待本机可用证书及公证配置。准备候选不等于正式包。

## 签名准备

需要有效的 **Developer ID Application** 证书及对应私钥。Apple Development、Apple Distribution、单独的 `.cer` 或 Apple ID 邮箱均不能替代这一签名身份。

本机 Xcode 已登录用户提供的开发者账户；团队证书管理中现有 Developer ID Application 显示 **Not in Keychain**，创建菜单不可用。经沙箱外 `security find-identity -v -p codesigning` 核对为 0 个有效身份。可以在原签名 Mac 的“钥匙串访问 → 我的证书”导出包含私钥的 `.p12`，在本机登录钥匙串中导入；若原私钥不可恢复，请由团队 Account Holder 配置新证书。本任务没有撤销或新建证书，不导出私钥。

导入完成后，在自己的终端核对：

```sh
security find-identity -v -p codesigning
```

输出应包含有效的 `Developer ID Application: …`。不要将 `.p12`、私钥或密码放入仓库；相关扩展名已加入 `.gitignore`。

## 公证凭据

在自己的终端交互式保存公证凭据，由系统提示输入 App 专用密码；不要把密码写在命令参数、脚本、日志或聊天中。Team ID 使用该证书所属开发团队的 ID。

```sh
xcrun notarytool store-credentials "codex-pulse-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"
```

也可使用已配置的 notarytool profile，或按 Apple 文档配置 App Store Connect API key。构建脚本只接收 profile 名称，交由官方工具从钥匙串读取，不读取或保存密码。现有 Xcode 登录不等于已经配置 notarytool profile。

## 正式打包

```sh
python3 scripts/package_release.py \
  --identity "Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)" \
  --notary-profile "codex-pulse-notary"
```

默认版本 `0.1.0`、构建号 `1`、通用架构 `arm64 + x86_64`，最低 macOS 14。可用 `--version`、`--build-number`、`--architecture` 指定；自定义钥匙串通过 `--keychain` 指定，该路径同时用于签名和公证。Intel 架构编译不等于 Intel 实机验收。

流程依次构建两个架构、合并应用与 helper、去除调试符号、验证有效 Developer ID、签名 helper 及应用（Hardened Runtime、安全时间戳），上传 ZIP 公证，将票据附到 `.app` 并验证 Gatekeeper；再生成带 Applications 快捷入口的 DMG，为 DMG 签名 / 公证 / 附票并验证。最终 ZIP 从已附票的应用生成。

输出在独立的 `dist/releases/版本-构建号-时间/`，保留旧产物，不替换当前驻留的本地应用、不安装、不改写 hooks 或偏好。交付内容为：

- `CodexPulse-版本-架构-notarized.dmg`：手动拖入 Applications 安装。
- `CodexPulse-版本-架构-notarized.zip`：包含已签名 / 附票的应用。
- `SHA256SUMS.txt`：两份最终文件的 SHA-256。
- `release.json`：版本、架构、源码提交及是否存在未提交变更、公证 ID 和校验值。

只有完整流程通过并生成 `release.json`、其中 `notarized=true` 才算分发完成。任一签名、公证、附票或 Gatekeeper 步骤失败都会退出，不退回 ad-hoc 冒充正式包。

公证提交 ID 会在等待前保存为 `app-submission.json` 或 `dmg-submission.json`。等待超时不会取消 Apple 服务端任务，不应反复上传；可使用其中 ID 和原 profile 执行 `xcrun notarytool wait` / `info`，取得 Accepted 后继续附票 / 验证。公证原始结果及日志仅留在被 Git 忽略的本地构建目录。

## 准备候选

证书尚未就绪时，可先验证便携构建和容器结构：

```sh
python3 scripts/package_release.py --prepare-only
```

产物文件名带 `candidate`，清单明确 `notarized=false`，使用 ad-hoc 签名；不用于正式分发。此模式不访问公证凭据、不上传 Apple，也不绕过 Gatekeeper。分发构建不嵌入开发机器的 CLI 路径、账户数据或偏好。

## 安装与首次使用

打开正式 DMG，将 `Codex Pulse.app` 拖到 Applications，弹出磁盘映像后从应用程序打开；升级前先退出旧实例。卸载可先在设置中关闭工作特效，再退出并将应用移到废纸篓；关闭仅移除 Pulse handlers，保留其它 hooks。

使用者需要已安装并登录的官方 Codex。应用优先发现官方桌面包内 CLI 和常见安装路径；若未找到，可在设置中选择 CLI 可执行文件。无需 Xcode、Python 或源码。

工作特效默认关闭，在设置中主动安装，然后到 Codex `/hooks` 审阅并信任全部定义，再检查连接。低额度提醒和开机启动仍默认关闭。签名或公证不替代这些用户选择，也不替代计划中明确延期的系统功能及自然重置实机观察。

流程依据：[Apple Developer ID](https://developer.apple.com/developer-id/)、[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
