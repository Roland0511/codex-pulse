# Build and distribution

[中文分发说明](DISTRIBUTION.md) · [Home](../README.md)

Requires macOS, Swift 6+, Xcode Command Line Tools, and Python 3. App runtime targets macOS 14+. Run:

```sh
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/generate_tokens.py --check
python3 scripts/generate_localizations.py --check
python3 scripts/build_app.py
```

The default app is built for the current Mac with an ad-hoc signature. `--portable` excludes the development machine's CLI path. `--architecture universal` compiles and merges arm64 / x86_64 for both the app and hook helper. Neither command installs anything or changes hooks.

## Developer ID release

Provide a valid Developer ID Application certificate and its private key in your own keychain. A public certificate alone, Apple ID email, Apple Development, or Apple Distribution identity cannot replace it. Keep private keys and passwords outside this repository.

Store notarization credentials interactively with Apple's `notarytool`; do not put passwords in commands or logs:

```sh
xcrun notarytool store-credentials "codex-pulse-notary" \
  --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID"
python3 -m venv .build/packaging
.build/packaging/bin/python -m pip install -r scripts/requirements-packaging.txt
.build/packaging/bin/python scripts/package_release.py \
  --identity "Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)" \
  --notary-profile "codex-pulse-notary"
```

Optional `--keychain` chooses a specific keychain for signing and notarization. The default version is 0.1.1 / build 3. The process signs the helper and app with hardened runtime and secure timestamps, notarizes the app, staples its ticket, creates the guided DMG, checks its embedded app, then signs, notarizes, and staples the DMG. The final ZIP contains the stapled app.

Only a complete run produces `release.json` with `notarized=true` and `SHA256SUMS.txt`. Distribute only the final `*-notarized.dmg` / ZIP; `notary-upload.zip` is an intermediate file. A failed run never falls back to ad-hoc as a release. Public signing certificates embedded in signatures are expected; private keys and notarization credentials are not included.

`--prepare-only` creates explicitly unnotarized `candidate` files without signing credentials or Apple uploads. For automation, configure access only for the intended signing private key and tools; GUI success does not prove unattended CI or SSH operation. Details and known packaging pitfalls are in [DISTRIBUTION.md](DISTRIBUTION.md).

## Translation and synthetic previews

Edit `Resources/Localization/en.json` and `zh-Hans.json`, then regenerate the immutable Swift catalog with `python3 scripts/generate_localizations.py`. The check validates matching keys and format arguments. `PulseText` formats values and `LanguageStore` owns active selection; UI code uses semantic keys.

After building, `python3 scripts/build_demo.py normal` creates a synthetic app. Quit the production instance before opening the demo; the single-instance lock applies to both. Demos use separate preferences and do not read the account or enable notifications, login items, or the global shortcut. Scenarios include normal, long, empty, unknown, loading, error, stale, logout, low, consuming, and working.

## Security checks

Before publication, scan the tracked tree and all publishable history. Current local builds, hook backups, raw account evidence, signing materials, and audit reports remain ignored. Never publish a private backup bundle. See [OPEN-SOURCE.md](OPEN-SOURCE.md) for the publication audit scope.
