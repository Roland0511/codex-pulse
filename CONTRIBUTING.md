# Contributing / 参与贡献

Focused fixes, compatibility reports, and improvements to Chinese or English copy are welcome. Open an issue before proposing changes to the capsule's frozen geometry or adding new product scope. Keep the app small; do not introduce conversation readers, agent controls, or account-changing APIs.

欢迎提交兼容性修复及中英文文案改进。修改冻结外形或扩展产品范围前，请先开 issue 讨论；保持极简，不引入对话读取、代理控制或账户修改接口。

Run the following before submitting a pull request:

```sh
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/generate_tokens.py --check
python3 scripts/generate_localizations.py --check
python3 scripts/build_app.py --portable
```

Translations belong in both JSON catalogs under `Resources/Localization/`; regenerate the Swift table rather than editing generated code. Preserve format arguments and verify both languages in the native app. Keep data tests synthetic. Distinguish automated tests, screenshot review, and real desktop interaction in your verification notes.

翻译在两份 JSON 中同步维护，重新生成 Swift 表；不要直接修改生成文件。使用合成数据，原生检查两种语言，并分别记录技术测试、截图抽查和真实交互。

Never include credentials, private keys, raw account responses, chat logs, hook backups, or unredacted screenshots. Read [SECURITY.md](SECURITY.md) for private reporting. Contributions are provided under this project's [MIT license](LICENSE).
