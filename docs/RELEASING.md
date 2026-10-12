# 一键正式发布

发布入口是 `scripts/release.py`。它在本机使用现有钥匙串完成构建、签名和公证，再上传 GitHub。无需导出 Developer ID 私钥或 Sparkle 私钥，也不需要把 Apple 凭据交给 GitHub Actions。GitHub 的 `Checks` 工作流继续负责合并后的代码检查；本机发布器只接受该源码对应的成功结果。

## 首次准备

在已授权的 macOS 构建机上准备 Xcode 命令行工具、Swift、Python 3、Git、已登录的 `gh`，以及有效的 Developer ID Application 身份、notarytool 钥匙串 profile 和 Sparkle Ed25519 密钥。证书必须属于本项目的 `ZHN9V7C8V3` 团队。钥匙串需要在当前登录会话可访问；系统仍可能要求解锁或签名授权。

```sh
python3 -m venv .build/packaging
.build/packaging/bin/python -m pip install -r scripts/requirements-packaging.txt
```

Sparkle 密钥账户固定为 `dev.roland.codex-pulse`，公钥必须与 `Resources/Updates.json` 一致。Git tag 使用已配置的签名身份；SSH 签名校验使用 `user.signingkey` 中的公钥。不要为发布器配置私钥导出、宽泛钥匙串授权或跳过签名的备用路径。

## 每次发布

1. 完成代码、版本相关说明及发行说明，提交并合并到 `main`，等待该提交的 `Checks` 成功。发行说明文件可以位于仓库外；内容在首次执行后冻结。
2. 更新本机 checkout，确保工作区干净。选择高于当前正式版的显示版本和 build；两者都必须递增。
3. 执行以下命令，将示例版本、build、证书和 profile 换成本次实际值：

```sh
.build/packaging/bin/python scripts/release.py \
  --version 0.2.1 --build-number 7 \
  --notes-file /path/to/release-notes.md \
  --identity "Developer ID Application: YOUR_NAME (ZHN9V7C8V3)" \
  --notary-profile "YOUR_SAVED_PROFILE"
```

版本和 build 显式传给构建器，不依赖开发构建的默认版本。证书、profile 与可选钥匙串路径也可分别由 `PULSE_SIGNING_IDENTITY`、`PULSE_NOTARY_PROFILE`、`PULSE_SIGNING_KEYCHAIN` 提供；这些变量只存引用，不存密码。

成功时打印公开发行链接。无需另行创建 tag、上传附件或修改更新清单。发布不替换本机已安装应用；开启自动更新的 Pulse 会使用新清单，手动安装也可使用正式 DMG。

## 强制检查顺序

- 核对正式 origin、干净源码、提交属于远端 main，以及该提交最新 main push 的 `Checks` 已成功。旧成功结果不能掩盖后来失败的结果。
- 核对当前正式版及已签名清单，拒绝版本或 build 回退；运行 Swift / Python 测试、设计 token 和本地化生成检查。
- 构建 arm64 + x86_64，逐层签名应用及 Sparkle 内嵌组件；应用与 DMG 均须 Apple `Accepted`，附加并验证票据，通过 Gatekeeper。
- 最终 ZIP 和 `appcast.xml` 分别使用 Ed25519 签名；生成覆盖 DMG、ZIP、签名清单的 `SHA256SUMS.txt`。
- 独立检查原应用、ZIP 解压副本和 DMG 挂载副本的版本、架构、嵌套签名、公证票据与更新配置，并验证 XML 下载地址、长度、build 和签名。拒绝撤回候选。
- 创建并验证签名 tag，推送后创建 GitHub 草稿。只上传 DMG、ZIP、`appcast.xml`、`SHA256SUMS.txt` 四个附件；重新下载逐字节对应摘要验证。
- 公开前重新核对源码、CI、版本和本地产物，再校验草稿。全部通过才公开并标为 Latest。
- 匿名下载四个公开附件，并检查 `releases/latest/download/appcast.xml` 与本次签名清单一致；完成后才写入成功记录。

以上是本项目支持的发布入口；在 GitHub 网页上手动发布会绕开本机检查，不属于自动化的保证范围。

## 中断与恢复

每个版本使用独立目录 `dist/releases/v版本-build构建号/`，包含 `publish-state.json`、`artifacts/package-state.json`、公证 ID、Apple 原始结果、正式文件和验证记录。这些文件被 Git 忽略，不上传源码仓库。全局文件锁阻止两次发布同时运行。

网络或公证等待超时后，在相同源码、版本、build、发行说明及身份参数下重新执行原命令。打包按已完成步骤恢复；已保存的公证提交只等待同一 ID，先核对上传字节摘要。签名清单生成完成后不会因为重试而重新写入时间戳。若原始提交响应未成功返回，客户端可能拿不到 ID，此时仍需核对 Apple 记录，不能把网络错误当作未提交。

已上传的草稿附件重新下载比较，缺失的才补传；不使用 `--clobber`。任何未知附件、字节变化、源码变化、发行说明变化、身份变化或发行 ID 变化都会停止。若服务端公证拒绝或产物需要修改，保留失败目录用于审计；修复源码后使用新的版本 / build，不能借用旧公证结果。

公开发行后若最后下载验证遇到网络错误，脚本会明确报失败并保留 `publishStarted`，此时发行可能已经公开。重试只验证已公开附件和最新清单，不覆盖或再次创建发行。脚本不自动删除 tag、发行或历史产物，不在失败时回退到未签名发布。

## 独立复核

可对已有正式发行做只读复核，不生成新版，也不上传附件：

```sh
.build/packaging/bin/python scripts/verify_release.py \
  dist/releases/0.2.0-6-20261013-002537 \
  --source e5927691324474c9f1132eb636ece55fb25ebaa9 --public
```

`--public` 同时要求该版仍是 Latest；检查较旧历史包时省略此参数。本地验证记录写入相应产物目录。

本次实现用现有 v0.2.0 实物验证了嵌套签名、双架构、公证票据、ZIP / DMG 副本、四个匿名下载及 Latest 清单同步。发布状态机的失败与恢复路径使用合成夹具验证；未为测试重复创建正式发行，也未宣称已在无登录会话或云端 runner 中完成签名。随后已通过统一入口正式发布 v0.2.1 和 v0.2.2，并完成公开附件与 Latest 清单验证。GitHub 按 tag 的 REST 查询对草稿返回 404 时，发布器会通过 `gh release view` 取得发行 ID，再读取草稿；不存在的发行与认证错误仍分别处理。
