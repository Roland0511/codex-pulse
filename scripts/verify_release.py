#!/usr/bin/env python3
"""独立核验正式产物和公开下载；任何检查失败都以非零状态退出。"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from build_app import ROOT
from package_release import save_json
from update_feed import ACCOUNT, SPARKLE, tool, verify_key

REPO = "Roland0511/codex-pulse"
TEAM = "ZHN9V7C8V3"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, timeout=180):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=True,
                            text=True, check=True, timeout=timeout, stdin=subprocess.DEVNULL)
    return result.stdout + result.stderr


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def asset_names(version):
    return {f"CodexPulse-{version}-universal-notarized.{extension}" for extension in ("zip", "dmg")} | {"appcast.xml", "SHA256SUMS.txt"}


def check_manifest(folder, source):
    require(not (folder / "WITHDRAWN.txt").exists(), "此候选已撤回")
    manifest = json.loads((folder / "release.json").read_text())
    require(re.fullmatch(r"\d+\.\d+\.\d+", manifest["version"]) and re.fullmatch(r"[1-9]\d*", manifest["build"]), "版本格式无效")
    require(manifest.get("sourceCommit") == source and manifest.get("sourceDirty") is False, "源码提交不匹配或构建时有未提交修改")
    require(manifest.get("notarized") is True and manifest.get("status") == "notarized" and manifest.get("signedFeed") is True, "不是正式公证和签名清单")
    require(set(manifest["architectures"]) == {"arm64", "x86_64"}, "非通用架构")
    expected = asset_names(manifest["version"]) - {"SHA256SUMS.txt"}
    require(set(manifest["sha256"]) == expected, "正式附件列表不完整")
    for name, sha in manifest["sha256"].items():
        require(digest(folder / name) == sha, name + " 摘要不匹配")
    require((folder / "SHA256SUMS.txt").read_text() == "".join(f"{sha}  {name}\n" for name, sha in manifest["sha256"].items()), "校验清单不匹配")
    for label in ("app", "dmg"):
        result = json.loads((folder / (label + "-result.json")).read_text())
        require(result.get("status") == "Accepted" and result.get("id") == manifest["submissions"][label], "公证状态不是 Accepted")
    return manifest


def inspect_app(app, manifest):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "dev.roland.codex-pulse", "应用标识不符")
    require(info["CFBundleShortVersionString"] == manifest["version"] and info["CFBundleVersion"] == manifest["build"], "应用版本不符")
    require("PulseCodexExecutable" not in info and not info.get("PulseDemoMode"), "含开发配置")
    config = json.loads(run("git", "show", manifest["sourceCommit"] + ":Resources/Updates.json"))
    require(info["SUPublicEDKey"] == config["publicEDKey"] and info["SUFeedURL"] == config["feedURL"], "更新源或公钥不符")
    require(info.get("SUVerifyUpdateBeforeExtraction") and info.get("SURequireSignedFeed") and info.get("SUSignedFeedFailureExpirationInterval") == 0, "更新验签策略不完整")
    hashes = {}
    framework = app / "Contents/Frameworks/Sparkle.framework"
    parts = [app / "Contents/MacOS" / name for name in ("CodexPulse", "PulseActivityHook")]
    parts += [framework / "Versions/B/Autoupdate", framework / "Versions/B/Updater.app", framework, app]
    for part in parts:
        run("codesign", "--verify", "--strict", "--all-architectures", part)
        for arch in ("arm64", "x86_64"):
            signature = run("codesign", "-d", "--arch", arch, "--verbose=4", part)
            require("Authority=Developer ID Application:" in signature and "TeamIdentifier=" + TEAM in signature and "Timestamp=" in signature and "(runtime)" in signature, "签名身份、时间戳或 Hardened Runtime 不符")
    for name in ("CodexPulse", "PulseActivityHook"):
        binary = app / "Contents/MacOS" / name
        require(set(run("lipo", "-archs", binary).split()) == {"arm64", "x86_64"}, "缺少架构")
        hashes[name] = digest(binary)
    hashes["Info.plist"] = digest(app / "Contents/Info.plist")
    run("xcrun", "stapler", "validate", app)
    assessment = run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    require("source=Notarized Developer ID" in assessment, "Gatekeeper 未识别公证")
    return hashes


def verify(folder, source):
    folder = pathlib.Path(folder).resolve()
    manifest = check_manifest(folder, source)
    verify_key()
    signer = tool("sign_update")
    zip_path = folder / f'CodexPulse-{manifest["version"]}-universal-notarized.zip'
    dmg = zip_path.with_suffix(".dmg")
    run(signer, "--account", ACCOUNT, "--verify", folder / "appcast.xml")
    run(signer, "--account", ACCOUNT, "--verify", zip_path, manifest["updateSignature"])
    items = ET.parse(folder / "appcast.xml").findall("channel/item")
    require(len(items) == 1, "更新清单必须仅包含当前版本")
    item = items[0]
    enclosure = item.find("enclosure")
    require(item.findtext("{" + SPARKLE + "}version") == manifest["build"] and item.findtext("{" + SPARKLE + "}shortVersionString") == manifest["version"], "清单版本不匹配")
    require(enclosure is not None and enclosure.get("url") == f'https://github.com/{REPO}/releases/download/v{manifest["version"]}/{zip_path.name}' and enclosure.get("length") == str(zip_path.stat().st_size) and enclosure.get("{" + SPARKLE + "}edSignature") == manifest["updateSignature"], "清单下载地址、长度或签名不匹配")
    original = inspect_app(folder / "Codex Pulse.app", manifest)
    run("codesign", "--verify", "--strict", dmg)
    signature = run("codesign", "-d", "--verbose=4", dmg)
    require("Authority=Developer ID Application:" in signature and "TeamIdentifier=" + TEAM in signature, "DMG 签名身份不符")
    run("xcrun", "stapler", "validate", dmg)
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
    with tempfile.TemporaryDirectory(prefix="pulse-release-verify-") as temporary:
        temp = pathlib.Path(temporary)
        run("ditto", "-x", "-k", zip_path, temp / "zip")
        require(inspect_app(temp / "zip/Codex Pulse.app", manifest) == original, "ZIP 内应用不匹配")
        mount = temp / "mount"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, dmg)
        try:
            require(inspect_app(mount / "Codex Pulse.app", manifest) == original, "DMG 内应用不匹配")
        finally:
            run("hdiutil", "detach", mount)
    report = {"sourceCommit": source, "version": manifest["version"], "build": manifest["build"], "sha256": manifest["sha256"], "verified": True}
    save_json(folder / "verification.json", report)
    return manifest


def release_metadata(tag):
    return json.loads(run("gh", "release", "view", tag, "--repo", REPO, "--json", "tagName,isDraft,isPrerelease,url,assets"))


def verify_downloads(folder, metadata, public=False):
    manifest = json.loads((folder / "release.json").read_text())
    tag = "v" + manifest["version"]
    require(metadata["tagName"] == tag and not metadata["isPrerelease"], "发行版本不符")
    require(not public or not metadata["isDraft"], "发行仍为草稿")
    require({asset["name"] for asset in metadata["assets"]} == asset_names(manifest["version"]), "远端附件缺失或多余")
    with tempfile.TemporaryDirectory(prefix="pulse-download-check-") as temporary:
        dest = pathlib.Path(temporary)
        for asset in metadata["assets"]:
            target = dest / asset["name"]
            if public:
                # --disable 不读取 curlrc；不传 GitHub 凭据，测试公开用户的真实下载。
                run("curl", "--disable", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--connect-timeout", "15", "--max-time", "150", "--output", target,
                    f'https://github.com/{REPO}/releases/download/{tag}/{asset["name"]}')
            else:
                run("gh", "release", "download", tag, "--repo", REPO, "--pattern", asset["name"], "--dir", dest)
            require(target.stat().st_size == asset["size"] and digest(target) == digest(folder / asset["name"]), "远端附件字节不匹配：" + asset["name"])
        if public:
            target = dest / "latest-appcast.xml"
            run("curl", "--disable", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--max-time", "150", "--output", target,
                f"https://github.com/{REPO}/releases/latest/download/appcast.xml")
            require(digest(target) == digest(folder / "appcast.xml"), "自动更新地址尚未同步到本次发行")
    save_json(folder / ("public-verification.json" if public else "draft-verification.json"), {"url": metadata["url"], "assets": metadata["assets"], "verified": True})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=pathlib.Path)
    parser.add_argument("--source", required=True)
    parser.add_argument("--public", action="store_true")
    args = parser.parse_args()
    try:
        manifest = verify(args.folder, args.source)
        if args.public:
            verify_downloads(args.folder, release_metadata("v" + manifest["version"]), public=True)
        print("正式产物核验通过" + ("，公开附件和自动更新清单已同步" if args.public else ""))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
