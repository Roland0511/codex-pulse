# macOS 手动分发

状态：2026-10-10 v0.1.0（构建 2）正式手动分发包完成，包含完整应用图标和中文拖放安装界面，已在真实 Finder 中确认。应用及 DMG 均通过 Developer ID 签名、Apple 公证、票据及 Gatekeeper；最终 ZIP 解压、DMG 包内应用只读核验和 SHA-256 独立复核通过。支持 arm64 / x86_64，最低 macOS 14；Intel 和旧系统仅完成编译，未做实机运行验收。

本次正式产物位于 `dist/releases/0.1.0-2-20261010-001426/`：

- `CodexPulse-0.1.0-universal-notarized.dmg`：优先使用的手动安装包。
- `CodexPulse-0.1.0-universal-notarized.zip`：已签名并附票的应用。
- `SHA256SUMS.txt`、`release.json`：校验值及构建来源。

分发上述最终 DMG 或 ZIP 即可；`notary-upload.zip` 是附票前的公证上传中间文件，不作为交付包。构建来源为 `290e09b`，开始打包时工作区干净，清单记录 `sourceDirty=false`；随后仅更新交付文档。

构建 1 保留为历史交付。首份美化构建 `0.1.0-2-20261010-000817` 虽获 Apple Accepted，但包内应用严格签名失败，已标记 `WITHDRAWN.txt`，不得分发；本次修复后的独立容器核验已通过。详细原因和验证边界见 [验证记录](VERIFICATION.md)。

## 签名准备

需要有效的 **Developer ID Application** 证书及对应私钥。Apple Development、Apple Distribution、单独的 `.cer` 或 Apple ID 邮箱均不能替代这一签名身份。

首次核对时，本机 Xcode 的团队证书显示 **Not in Keychain**，创建菜单不可用，钥匙串为 0 个有效身份。用户随后自行导入含私钥的证书；复核已有 1 个有效 Developer ID Application 身份，原证书缺失问题已解除。本任务没有撤销或新建证书，不导出私钥。

其它构建机器若缺少证书，可在原签名 Mac 的“钥匙串访问 → 我的证书”导出包含私钥的 `.p12`，在目标机器的登录钥匙串中导入；若原私钥不可恢复，请由团队 Account Holder 配置新证书。

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

首次使用私钥时，macOS 可能为 helper、应用和 DMG 的 codesign 操作弹出钥匙串授权。保存私钥访问规则时的 `kcproxy` 管理员提示用于修改系统钥匙串，公证 profile 则用于向 Apple 服务认证，二者分别处理。由用户在系统窗口输入本机密码；电脑操作工具不能访问 SecurityAgent，不将密码发送到聊天或脚本。

## 重复打包与自动化

已保存的 notarytool profile 可供后续公证复用，本次应用与 DMG 的两次真实提交均成功。避免重复签名授权，需要让目标私钥信任系统 `/usr/bin/codesign`；只为该私钥新增此工具，保留原有规则，不选择允许所有应用。修改系统钥匙串规则时仍可能要求一次管理员确认。本机已按用户明确授权完成该设置；重启钥匙串访问后核对新增项持久保留，连续两次临时副本 Developer ID 签名及严格全架构验证通过，无交互输入。完整记录见 `VERIFICATION.md`。

钥匙串解锁状态及进程执行上下文也影响签名；GUI 会话中的验证不能证明退出登录、SSH 或 CI 均可直接使用。后续配置 CI 时宜使用独立构建钥匙串及 CI 的秘密存储，在任务中定向导入和授权签名身份；不对整个登录 / 系统钥匙串批量放宽 ACL 或分区规则，也不把凭据写入仓库或普通日志。参见 [Apple 对签名授权及无 GUI 环境的说明](https://developer.apple.com/forums/thread/712005)。

## 正式打包

源码构建仍使用 Python 标准库和本机 Swift / AppKit。制作带 Finder 背景及布局的 DMG 另需固定版本 `dmgbuild`，安装到独立构建环境，不修改系统 Python：

```sh
python3 -m venv .build/packaging
.build/packaging/bin/python -m pip install -r scripts/requirements-packaging.txt
```

```sh
.build/packaging/bin/python scripts/package_release.py \
  --identity "Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)" \
  --notary-profile "codex-pulse-notary"
```

默认版本 `0.1.1`、构建号 `3`、通用架构 `arm64 + x86_64`，最低 macOS 14。可用 `--version`、`--build-number`、`--architecture` 指定；自定义钥匙串通过 `--keychain` 指定，该路径同时用于签名和公证。Intel 架构编译不等于 Intel 实机验收。

流程依次构建两个架构、合并应用与 helper、去除调试符号、验证有效 Developer ID、签名 helper 及应用（Hardened Runtime、安全时间戳），上传 ZIP 公证，将票据附到 `.app` 并验证 Gatekeeper；再生成带 Applications 快捷入口的 DMG，只读挂载并验证其中应用 / helper 的严格全架构签名、应用票据及 Gatekeeper，卸载后再为 DMG 签名 / 公证 / 附票并验证。最终 ZIP 从已附票的应用生成。

完整 ICNS 在签名前写入应用 Resources，Info.plist 指向同一图标。原生矢量图稿复用冻结色板；Retina 背景及 Finder 图标位置共用布局参数。DMG 仅显示应用和 `Applications` 快捷入口，中英双语安装提示直接置于背景；不依赖 Finder 自动排列，也不修改用户的全局显示偏好。构建依据 [dmgbuild 的设置说明](https://dmgbuild.readthedocs.io/en/latest/settings.html)。

不向已签名的应用写入 FinderInfo 或自定义资源叉；图标通过应用 Resources 提供，扩展名是否显示遵循 Finder 偏好。此类元数据会使严格签名核验失败，参见 [Apple QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html)。DMG 外层签名 / 公证成功不能替代包内应用的验证。

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
.build/packaging/bin/python scripts/package_release.py --prepare-only
```

产物文件名带 `candidate`，清单明确 `notarized=false`，使用 ad-hoc 签名；不用于正式分发。此模式不访问公证凭据、不上传 Apple，也不绕过 Gatekeeper。分发构建不嵌入开发机器的 CLI 路径、账户数据或偏好。

## 安装与首次使用

打开正式 DMG，将 `Codex Pulse.app` 拖到右侧 `Applications`，弹出磁盘映像后从应用程序打开；升级前先退出旧实例。也可在 Finder 选择应用后按 `⌘C`，再按 `⇧⌘A` 打开应用程序文件夹，按 `⌘V` 安装。卸载可先在设置中关闭工作特效，再退出并将应用移到废纸篓；关闭仅移除 Pulse handlers，保留其它 hooks。

使用者需要已安装并登录的官方 Codex。应用优先发现官方桌面包内 CLI 和常见安装路径；若未找到，可在设置中选择 CLI 可执行文件。无需 Xcode、Python 或源码。

工作特效默认关闭，在设置中主动安装，然后到 Codex `/hooks` 审阅并信任全部定义，再检查连接。低额度提醒和开机启动仍默认关闭。签名或公证不替代这些用户选择，也不替代计划中明确延期的系统功能及自然重置实机观察。

流程依据：[Apple Developer ID](https://developer.apple.com/developer-id/)、[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
