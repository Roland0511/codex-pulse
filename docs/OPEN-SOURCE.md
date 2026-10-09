# 开源与隐私检查

2026-10-10 用户授权将私有仓库公开，采用 MIT，并加入中英文文档和应用语言支持。公开是最后一步：先验证、脱敏、推送，再切换可见性。

## 公开范围

源码、设计参数、独立图稿、合成夹具、构建脚本和工程文档采用 MIT。中英文 README 与使用指南均包含安装、隐私和限制说明。首份开源分发为 0.1.1 / build 3；正式包须通过 Developer ID、Apple 公证、票据、Gatekeeper 及最终容器检查后才发布。

## 检查与处理

- 初查仓库为私有、无许可证、无 Release 附件、无 Actions 历史，issue 数为 0。检查远端分支 / tag，扫描全部可达文件版本。
- Gitleaks 8.30.1 对开源前 7 个提交扫描约 514 KB，未发现密钥。另查私钥标头、证书 / 认证文件名、个人绝对路径和邮箱；文件命中仅为合成测试邮箱和图稿文件名误匹配。
- 提交元数据有个人工作邮箱。已先生成只留本机的私有恢复 bundle；已将待公开 main 的 8 个提交统一为 GitHub 公开用户名及 noreply 邮箱，并在私有状态推送；全新远端克隆复查 140 个 blob，无私钥、个人路径或个人邮箱命中。旧构建清单中的提交号属于历史私有证据，源码内容与原验收记录保留，不能当成重写后的公开提交号。
- `dist/`、`.build/`、`local-data/`、`private-evidence/`、日志、环境文件、私钥、证书和钥匙串扩展名被 Git 忽略。忽略规则不等于历史清理，最终还须重新扫描公开分支及全新克隆。
- 公开产品图由本项目脚本生成，所有额度与时间均为明确标注的合成示意。真实桌面截图、账户响应、hook 备份和签名凭据不提交。
- 正式应用签名内的 Developer ID 公共证书属于正常公开签名身份；它不含私钥或公证 profile。只上传最终 DMG、ZIP 和校验值，不上传中间文件、整个构建目录或恢复 bundle。

## 状态

当前：实现、原生中英切换及公开分支审计已完成；88 份待公开文件和重写后全部历史的 Gitleaks 扫描通过。最终分发检查、远端 CI 与公开访问验证进行中。完成后在本节追加真实结果；未执行的检查不计通过。后续用户报告应遵循 [SECURITY.md](../SECURITY.md)，不在公开 issue 中提交真实数据。

English summary: publication is gated on a tracked-tree and history audit, public commit identity, synthetic artwork, bilingual runtime verification, and signed-container checks. Local credentials, raw evidence, and recovery bundles are excluded. Historical private build hashes are provenance records, not rewritten public commit IDs.
