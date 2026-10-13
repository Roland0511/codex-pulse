# macOS 手动分发

2026-10-13 当前公开分发：[v0.2.2 / build 8](https://github.com/Roland0511/codex-pulse/releases/tag/v0.2.2)。展开卡片完成精简和点击区域修复；自动发布流程已执行真实发布，本机通过应用内更新安装。应用与 DMG 的 Apple 公证、签名、票据、Gatekeeper，以及公开附件和更新清单校验通过。历史交付记录保留如下。

历史交付状态：2026-10-10 v0.1.0（构建 2）正式手动分发包完成，包含完整应用图标和中文拖放安装界面，已在真实 Finder 中确认。应用及 DMG 均通过 Developer ID 签名、Apple 公证、票据及 Gatekeeper；最终 ZIP 解压、DMG 包内应用只读核验和 SHA-256 独立复核通过。支持 arm64 / x86_64，最低 macOS 14；Intel 和旧系统仅完成编译，未做实机运行验收。

历史 build 2 产物位于 `dist/releases/0.1.0-2-20261010-001426/`：

- `CodexPulse-0.1.0-universal-notarized.dmg`：优先使用的手动安装包。
- `CodexPulse-0.1.0-universal-notarized.zip`：已签名并附票的应用。
- `SHA256SUMS.txt`、`release.json`：校验值及构建来源。

分发上述最终 DMG 或 ZIP 即可；`notary-upload.zip` 是附票前的公证上传中间文件，不作为交付包。构建来源为 `290e09b`，开始打包时工作区干净，清单记录 `sourceDirty=false`；随后仅更新交付文档。

构建 1 保留为历史交付。首份美化构建 `0.1.0-2-20261010-000817` 虽获 Apple Accepted，但包内应用严格签名失败，已标记 `WITHDRAWN.txt`，不得分发；本次修复后的独立容器核验已通过。详细原因和验证边界见 [验证记录](VERIFICATION.md)。

## v0.1.3 / build 5 正式发布（2026-10-13）

- [PR #4](https://github.com/Roland0511/codex-pulse/pull/4) 已合并，issue #3 已随合并关闭。正式发布地址见页首。
- 干净源码 `e56699798abc4fab1cd8190e2a7f2591aa4d97e8`，签名 tag `v0.1.3` 指向该提交，`sourceDirty=false`；发布构建 CI [38275567384](https://github.com/Roland0511/codex-pulse/actions/runs/38275567384) 通过，含 80 项 Swift 回归。后续提交仅更新交付文档。
- 产物目录 `dist/releases/0.1.3-5-20261013-001044/`；应用和 helper 均为 `arm64 + x86_64`。Apple 对应用和 DMG 分别返回 Accepted；两者附票、严格全架构签名及 Gatekeeper 验证通过。
- 最终 ZIP 解压副本、只读挂载 DMG 内应用独立复核通过；十种图标表示、双语画布及 Finder 布局、固定模型目录与源码一致性、无本机开发路径和凭据标记检查通过，临时挂载已卸载。
- 公开附件仅为 DMG（2,662,169 bytes）、ZIP（1,966,284 bytes）和 SHA256SUMS.txt（214 bytes）。禁用认证后匿名重新下载，三者逐字节一致；公开仓库重新克隆、tag 对应提交和全历史 Gitleaks 扫描通过。
- DMG SHA-256：`2800df6d39bf91f5ecb697f42056553caebabc5458cc3c852789a3a4f55b1e94`。
- ZIP SHA-256：`1b1eb36d7935a8ffed9f5c5aed8f4f2368b1ef9d44cafd05db1b10ac617a0d01`。
- 本机应用由公开 ZIP 更新为 0.1.3 / build 5，旧应用留在忽略目录 `local-data/issue-3/install-backup/`，可回退。安装后签名、票据、Gatekeeper 通过，应用二进制与发布文件一致，单实例运行。
- 原生界面确认额度读取、手动刷新更新时间、工作状态文本及「已启用，连接就绪」。原有 hooks 和已安装 helper 字节不变，通知 / 开机启动保持关闭，工作特效保持开启，语言 / 外观 / 快捷键保持原选择。验收展开详情后曾改写垂直位置，随后只恢复原 `overlayPosition` 并重启；未重装 hooks 或改写信任。
- 技术、安装与本次原生界面检查仅覆盖以上内容；未将它们当作多屏、拖动、动画全矩阵、Intel 或真实休眠恢复验收。

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

完整新版发布请使用 [一键正式发布](RELEASING.md) 的 `scripts/release.py`，它自动执行以下打包步骤并上传、核验签名更新清单。此节保留仅生成本地正式包的用法。

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

默认版本 `0.2.2`、构建号 `8`、通用架构 `arm64 + x86_64`，最低 macOS 14。可用 `--version`、`--build-number` 指定；正式更新包要求通用架构，候选包才可通过 `--architecture` 选择单架构。自定义钥匙串通过 `--keychain` 指定，该路径同时用于签名和公证。Intel 架构编译不等于 Intel 实机验收。

流程依次构建两个架构、合并应用与 helper、去除调试符号、验证有效 Developer ID、签名 helper 及应用（Hardened Runtime、安全时间戳），上传 ZIP 公证，将票据附到 `.app` 并验证 Gatekeeper；再生成带 Applications 快捷入口的 DMG，只读挂载并验证其中应用 / helper 的严格全架构签名、应用票据及 Gatekeeper，卸载后再为 DMG 签名 / 公证 / 附票并验证。最终 ZIP 从已附票的应用生成。

完整 ICNS 在签名前写入应用 Resources，Info.plist 指向同一图标。原生矢量图稿复用冻结色板；Retina 背景及 Finder 图标位置共用布局参数。DMG 仅显示应用和 `Applications` 快捷入口，中英双语安装提示直接置于背景；不依赖 Finder 自动排列，也不修改用户的全局显示偏好。构建依据 [dmgbuild 的设置说明](https://dmgbuild.readthedocs.io/en/latest/settings.html)。

不向已签名的应用写入 FinderInfo 或自定义资源叉；图标通过应用 Resources 提供，扩展名是否显示遵循 Finder 偏好。此类元数据会使严格签名核验失败，参见 [Apple QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html)。DMG 外层签名 / 公证成功不能替代包内应用的验证。

输出在独立的 `dist/releases/版本-构建号-时间/`，保留旧产物，不替换当前驻留的本地应用、不安装、不改写 hooks 或偏好。交付内容为：

- `CodexPulse-版本-架构-notarized.dmg`：手动拖入 Applications 安装。
- `CodexPulse-版本-架构-notarized.zip`：包含已签名 / 附票的应用。
- `appcast.xml`：已签名的自动更新清单，包含最终 ZIP 的 Ed25519 签名。
- `SHA256SUMS.txt`：DMG、ZIP 和签名清单三份最终文件的 SHA-256。
- `release.json`：版本、架构、源码提交及是否存在未提交变更、公证 ID 和校验值。

只有完整流程通过并生成 `release.json`、其中 `notarized=true` 才算分发完成。任一签名、公证、附票或 Gatekeeper 步骤失败都会退出，不退回 ad-hoc 冒充正式包。

公证提交 ID 会在等待前保存为 `app-submission.json` 或 `dmg-submission.json`。使用 `--output-dir` 固定目录后，重复同一命令会验证输入并恢复已保存的构建步骤；等待超时继续等待同一公证 ID，不重新上传。公证原始结果及日志仅留在被 Git 忽略的本地构建目录。只读复核使用 `scripts/verify_release.py`。

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

## v0.1.1 公开分发的独立复核

- 当前产物目录 `dist/releases/0.1.1-3-20261010-004412/`，构建来源 `037d477`、`sourceDirty=false`；后续仅更新文档。
- 发布文件 `CodexPulse-0.1.1-universal-notarized.dmg`，SHA-256：`1552603b314303e3fa2aa15a5d1dd5dfd54d242898c2d72625b5508038ca64a8`。
- 发布文件 `CodexPulse-0.1.1-universal-notarized.zip`，SHA-256：`aaf6d3a50b25ad2cf23f2c8b15b961a5337860a6cf4ecb6913f741a97bd52fa9`。
- 原应用、最终 ZIP 解压及 DMG 只读挂载下应用 / helper 的 arm64、x86_64、严格签名、Hardened Runtime、安全时间戳、票据和 Gatekeeper 通过，关键文件内容一致。十种图标表示、MIT 原文、语言声明、无开发 CLI / Demo 标记、无个人路径 / 公证配置 / 私钥标记通过。
- 初次状态查询反复超时，先取得真实应用票据并完成 ZIP 验证。解锁后查回应用 Accepted，并完成 DMG 的真实 Accepted、附票、严格签名及 Gatekeeper；原 ZIP 字节和校验值保持不变。票据流程参考 [Apple 官方说明](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
- 真实 Finder 中确认最终 DMG 的图标、中英文提示、箭头及底部说明完整。发布附件仅含最终 DMG、ZIP 和校验值；不包含中间上传文件、构建目录或日志。

## v0.1.2 / build 4 正式发布（2026-10-12）

- 发布地址：[v0.1.2](https://github.com/Roland0511/codex-pulse/releases/tag/v0.1.2)。修复 [issue #1](https://github.com/Roland0511/codex-pulse/issues/1)，PR #2 已合并。
- 干净构建源码 `2b04f11aad8cebc1e8e23be67aa60c9941e7959b`，`sourceDirty=false`；签名 tag `v0.1.2` 指向该源码。合并提交 `810fbeb` 与构建源码树一致，远端 macOS CI 通过；发布后只更新交付文档。
- 产物目录 `dist/releases/0.1.2-4-20261012-215501/`；应用及 helper 均含 `arm64 + x86_64`，最低 macOS 14，版本 0.1.2 / build 4。随包 `QuotaModelCatalog.json` 与源码一致，MIT 许可及 en / zh-Hans 声明正确，无开发 CLI 路径或演示标记。
- 应用和 DMG 两次 Apple 公证均返回 `Accepted`，原始提交 / 结果仅保留在忽略的产物目录。Developer ID 全架构严格签名、Hardened Runtime、安全时间戳、stapler、Gatekeeper 通过；最终 ZIP 解压副本和只读挂载 DMG 内的应用独立通过同样检查，临时挂载已卸载。
- 安装画布的背景尺寸 / 分辨率、图标及 `.DS_Store` 布局参数独立检查通过；本次没有新增真实 Finder 操作或桌面交互验收，不替代既有记录。
- 正式公开附件仅有 DMG（2,622,251 bytes）、ZIP（1,930,527 bytes）、`SHA256SUMS.txt`（214 bytes）。发布后禁用认证匿名下载三者，逐字节及 SHA-256 均与本地验证产物一致；无公证上传中间包。
- DMG SHA-256：`614fca968cee304906406fc5fc5ae45d100b6c17463d36761aba00a3a6153320`。
- ZIP SHA-256：`e0bb161e501afcfff192e0bbfc9cc2189295d1ac6f36896d5aad937995f2a6a2`。
- 禁用凭据的公开仓库全新克隆与 Gitleaks 全历史扫描通过。本地报告位于忽略目录 `local-data/issue-1/`，未将真实账户响应、身份或公证凭据提交到 Git。
- 未安装 / 覆盖本机应用，未重新验证 Intel 实机、Ultrafast、真实会话上下文、拖动、多屏或休眠恢复。


## Sparkle 更新发布（v0.2.0 起）

正式流程现在同时需要已配置的 Sparkle Ed25519 私钥（系统钥匙串账户 `dev.roland.codex-pulse`，公钥见 `Resources/Updates.json`）。构建会固定下载并嵌入 Sparkle 2.10.0，保留许可，分别签名更新 helper 和 framework，再签名应用；不把私钥或账号认证数据打入安装包。

`package_release.py` 在两份安装包完成公证后自动创建、签名、验签 `appcast.xml`；SHA256SUMS.txt 同时列出 DMG、ZIP、feed。正式发布应先上传到 draft release，确认四个附件完整后再公开，避免用户请求到缺失清单。`SUFeedURL` 指向最新发布附件中的 appcast.xml。具体开关、安装时机与测试边界见 [UPDATES.md](UPDATES.md)。


## v0.2.0 / build 6 正式发布（2026-10-13）

- [PR #5](https://github.com/Roland0511/codex-pulse/pull/5) 已合并，签名 tag `v0.2.0` 指向干净构建源码 `e5927691324474c9f1132eb636ece55fb25ebaa9`；其源码树与合并提交 `75973cb` 一致。CI [38277143244](https://github.com/Roland0511/codex-pulse/actions/runs/38277143244) 通过。
- 产物目录 `dist/releases/0.2.0-6-20261013-002537/`，`sourceDirty=false`，arm64 + x86_64。应用和 DMG 两次公证均为 Accepted，完整容器独立核验通过。
- 正式附件：DMG 3,643,866 bytes、ZIP 3,007,256 bytes、已签名 appcast.xml 1,452 bytes、SHA256SUMS.txt 292 bytes。匿名资产下载与本地逐字节一致。
- DMG SHA-256：`47f610780ae30ac4c576c8bae2e9b0ae81cb84ff6ccaeae029a3eea5d1373167`。
- ZIP SHA-256：`2b5471e56d2e777fd453dcba8d8a9ba08eca56a65a69384ad641fe4f6f6761f0`。
- appcast.xml SHA-256：`ca811fbf3dba36183656ca220ab6942f405494493ca6c0f105c368e77696d23c`。
- 本机已安装正式版本；独立低版本测试包的手动安装重启、自动下载与退出自动安装全部完成，详见 [UPDATES.md](UPDATES.md)。Intel 仍仅交叉编译，未新增 Intel 实机验收。
- 首轮 Swift 6.1 编译失败对应的旧候选 `0.2.0-6-20261013-002306/` 已标记 WITHDRAWN，未公开分发；不能与正式产物混用。

## v0.2.2 / build 8（2026-10-13）

- 来源 `9a944dd8321103614bb68d6ee3d7e5b3add161b4`，main CI 38281949929 通过，源码干净。PR #7 为卡片改版，后续提交修复原生拖动层与按钮的点击区域。
- `scripts/release.py` 完成签名 tag、草稿上传、公开及匿名下载校验，四个附件与本地产物一致，Latest 更新清单已同步。
- 应用、DMG 均为 Apple Accepted；包内应用与 Sparkle 嵌套代码、双架构、票据和 Gatekeeper 独立核验通过。
- `CodexPulse-0.2.2-universal-notarized.dmg` SHA-256：`fa07c82dda69f106a9f40e2ccd327e6da510ed032e423405644c187ba879eb50`。
- `CodexPulse-0.2.2-universal-notarized.zip` SHA-256：`36df53abc53c33525f408d15401c0e894779740df4b69339b0aa242c7194c4f9`。
- `appcast.xml` SHA-256：`05acaf289bde5e0565fd06b6d3b4b3f2a67a3197f8c4cf0176e74b73eacafa6a`。

- 本机通过 Sparkle 从 0.2.1 升级到 0.2.2；安装后的二进制与正式包一致，签名 / Gatekeeper 通过，语言、外观、快捷键、图钉及自动更新偏好语义保持不变。
- 首次 0.2.1 草稿查询失败发生在公开前；空草稿已归档后撤回，旧产物标记 WITHDRAWN。发布器改为按发行 ID 读取草稿，并增加回归测试。后续两次公开发布均走修复后的校验流程。

## v0.3.0 / build 9（2026-10-13）

- [公开发行](https://github.com/Roland0511/codex-pulse/releases/tag/v0.3.0)包含 Codex 窗口跟随与重叠目标选择；PR #8 已合并，随后补齐跨屏可见区域保护。
- 构建源码 `b05980d241d28d0d34f2399eaaad1a20456a37d4`，`sourceDirty=false`；[main CI 38284364833](https://github.com/Roland0511/codex-pulse/actions/runs/38284364833) 成功，签名 tag 指向该源码。
- 应用与 DMG 均为 Apple Accepted，附票、Gatekeeper、ZIP / DMG 内应用和嵌套 Sparkle 签名独立验证通过。通用架构包含 arm64 + x86_64。
- `scripts/release.py` 完成草稿上传、附件核验、公开发行、四个匿名下载以及 Latest 更新清单同步验证。
- `CodexPulse-0.3.0-universal-notarized.dmg` SHA-256：`ea34ae841d28eb835ec7b7ba61db114894597ebe63dacc8900a27da222c1ec62`。
- `CodexPulse-0.3.0-universal-notarized.zip` SHA-256：`517fd9845a505773344912d9d6609c2ea0ad79c8d0639e5aca4bc00fd81f8df9`。
- `appcast.xml` SHA-256：`508ea3ca09c29d3635d884c958eabf3174ff6a6b005d2966d2f3e47da4d1be3d`。
- 本机从公开 ZIP 更新为 0.3.0 / build 9，应用二进制和 helper 与公开包一致；签名、票据、Gatekeeper 和单实例通过，安装前后的偏好语义一致。旧版应用与偏好备份保留在本机。
- 首轮源码 `2464ba5` 的未公开候选在发布前撤回，保留于本机 `withdrawn-v0.3.0-build9-2464ba5/`；没有为它创建 tag 或公开发行。其 Apple 提交记录保留，不能当作本次发布产物。
- 原生菜单可见性与合成几何 / 生命周期回归不等于真实窗口移动、多屏或全屏验收；手动交互边界见 [验证记录](VERIFICATION.md)。


## v0.3.2 / build 11（2026-10-13）

- [公开发行](https://github.com/Roland0511/codex-pulse/releases/tag/v0.3.2)包含流畅窗口跟随、失焦保留和静止节能。PR #9、#10 已合并。
- 构建源码 `0724db6e34a0c9cabadad0f3aea87f1adaf0b4f4`，`sourceDirty=false`；[main CI 38354711020](https://github.com/Roland0511/codex-pulse/actions/runs/38354711020) 成功，签名 tag 指向该源码。
- 应用和 DMG 的 Apple 公证均为 Accepted；双架构、附票、Gatekeeper、嵌套签名及 ZIP / DMG 内应用独立核验通过。
- 发布器完成草稿上传、附件回读、四个匿名下载及 Latest 签名更新清单同步核验。
- `CodexPulse-0.3.2-universal-notarized.dmg` SHA-256：`5f57f354e9d92c156beb7fad054e7431e51896d47da78d50b7dc72c1f261caf0`。
- `CodexPulse-0.3.2-universal-notarized.zip` SHA-256：`21c2910c7e7f63819eb8b1df035dc6cae82c08025c4dca2aec9855db9b118906`。
- `appcast.xml` SHA-256：`d563870478ab83358395ae079f8019f67677a5a2d697e9607bfc4ab5d71bff7a`。
- 本机由公开 ZIP 更新到 0.3.2 / build 11，应用与 helper 摘要一致；签名、票据、Gatekeeper、单实例及额度读取正常，偏好语义不变。旧版应用与安装前偏好保留于本机。
- 0.3.1 / build 10 在收到静止节能补充要求后于公开前撤回；保留其签名 tag `v0.3.1` 和公证记录，没有 GitHub 发行或发行附件。旧候选本地标记 WITHDRAWN，不能与正式版本混用。
- 原生程序移动、查询计时与展开测试见 [验证记录](VERIFICATION.md)。实际鼠标拖动、多屏和全屏仍保留用户实机验收边界。
