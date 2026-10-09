# Security / 安全报告

For a vulnerability, use GitHub's [private vulnerability reporting](https://github.com/Roland0511/codex-pulse/security/advisories/new). Do not include exploits, credentials, or private data in public issues. Describe affected versions, impact, and minimal reproduction using synthetic data. Do not attach `~/.codex/auth.json`, cookies, raw account responses, transcripts, signing private keys, hook backups, or notarization credentials.

发现漏洞请使用 GitHub [私密漏洞报告](https://github.com/Roland0511/codex-pulse/security/advisories/new)，不要在公开 issue 中附带凭据、私有数据或可直接滥用的细节。提供受影响版本、影响和使用合成数据的最小复现。不要上传认证文件、Cookie、原始账户响应、对话、签名私钥、钩子备份或公证凭据。

The current release is the supported line. Codex protocol compatibility may change between versions. Quota reading is read-only; optional hook installation requires explicit user action and preserves other handlers. Developer ID public certificates embedded in release signatures are public identity information, not private key material.

当前版本为维护范围，Codex 协议可能随版本变化。额度读取只读；可选钩子安装需用户主动确认并保留其它 handlers。分发签名中的 Developer ID 公共证书属于公开身份信息，不包含签名私钥。
