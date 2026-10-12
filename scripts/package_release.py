#!/usr/bin/env python3
"""生成便携 DMG / ZIP；正式流程必须 Developer ID 签名、公证和 Gatekeeper 通过。"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile

from build_app import sign, signing_identity
from artwork import generate as generate_artwork
from update_feed import generate as generate_feed, verify_key

ROOT = pathlib.Path(__file__).resolve().parents[1]


def save_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def run(*args, capture=False):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True,
                          stdout=subprocess.PIPE if capture else None, text=True).stdout


def archive(app, target):
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, target)


def notarize(upload, staple_target, authentication, folder, label):
    # 只恢复同一份字节的提交；超时不会重新上传，改过的包不能借用旧公证。
    record = folder / (label + "-submission.json")
    digest = hashlib.sha256(upload.read_bytes()).hexdigest()
    if record.exists():
        result = json.loads(record.read_text())
        if result.get("uploadSHA256") != digest:
            raise ValueError(label + " 公证输入已变化；请使用新的发布目录")
    else:
        result = json.loads(run("xcrun", "notarytool", "submit", upload, *authentication,
                                "--output-format", "json", "--no-progress", capture=True))
        result["uploadSHA256"] = digest
        save_json(record, result)
    identifier = result["id"]
    print(label + " 公证提交：" + identifier, flush=True)
    result = json.loads(run("xcrun", "notarytool", "wait", identifier, *authentication,
                            "--timeout", "20m", "--output-format", "json", capture=True))
    save_json(folder / (label + "-result.json"), result)
    if result.get("status") != "Accepted":
        run("xcrun", "notarytool", "log", identifier, *authentication, folder / (label + "-notary-log.json"))
        raise ValueError(label + " 未通过公证，不能作为正式分发包")
    # ZIP 不支持票据；上传 ZIP 时向其内含的 .app 附加票据。
    run("xcrun", "stapler", "staple", staple_target)
    run("xcrun", "stapler", "validate", staple_target)
    return identifier


def verify_disk_image(dmg, notarized):
    # 容器签名不证明包内应用有效；Finder 元数据也可能破坏严格验证。
    with tempfile.TemporaryDirectory(prefix="pulse-release-check-") as directory:
        mount = pathlib.Path(directory)
        attached = False
        try:
            run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, dmg)
            attached = True
            app = mount / "Codex Pulse.app"
            for path in (app / "Contents/MacOS/PulseActivityHook", app):
                run("codesign", "--verify", "--strict", "--all-architectures", path)
            if notarized:
                run("xcrun", "stapler", "validate", app)
                run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
        finally:
            if attached:
                run("hdiutil", "detach", mount)


def package(args):
    if not args.prepare_only and not (args.identity and args.notary_profile):
        raise ValueError("正式分发必须指定 --identity 和 --notary-profile；准备候选请明确使用 --prepare-only")
    if args.prepare_only and (args.identity or args.notary_profile or args.keychain):
        raise ValueError("准备候选不会使用签名 / 公证凭据，不接受这些参数")
    if not args.prepare_only and args.architecture != "universal":
        raise ValueError("自动更新正式包必须包含 arm64 与 x86_64")
    if importlib.util.find_spec("dmgbuild") is None:
        raise ValueError("缺少 DMG 构建依赖。请按 docs/DISTRIBUTION.md 创建独立构建环境并安装 scripts/requirements-packaging.txt。")
    if not args.prepare_only:
        run("swift", "package", "resolve")
        verify_key()
    # 在任何构建或上传前记录源码状态，避免中途修改文档影响来源判定。
    source_commit = run("git", "rev-parse", "HEAD", capture=True).strip()
    source_dirty = bool(run("git", "status", "--porcelain", capture=True).strip())
    if source_dirty and not args.prepare_only:
        raise ValueError("正式构建要求干净的源码工作区")
    label = "candidate" if args.prepare_only else "notarized"
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    folder = getattr(args, "output_dir", None) or ROOT / "dist/releases" / (args.version + "-" + args.build_number + "-" + stamp)
    folder = pathlib.Path(folder).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    state_path = folder / "package-state.json"
    inputs = {"source": source_commit, "version": args.version, "build": args.build_number,
              "architecture": args.architecture, "identity": args.identity,
              "prepareOnly": args.prepare_only}
    if state_path.exists():
        state = json.loads(state_path.read_text())
        if state["inputs"] != inputs:
            raise ValueError("发布目录与本次源码 / 参数不匹配")
    else:
        if any(folder.iterdir()):
            raise ValueError("发布目录必须为空或包含本流程的恢复记录")
        state = {"inputs": inputs, "completed": []}
        save_json(state_path, state)
    def step(name, operation):
        if name not in state["completed"]:
            operation()
            state["completed"].append(name)
            save_json(state_path, state)
    base = "CodexPulse-" + args.version + "-" + args.architecture
    build_command = [sys.executable, "scripts/build_app.py", "--portable", "--architecture", args.architecture,
                     "--version", args.version, "--build-number", args.build_number, "--output-dir", str(folder)]
    if args.identity:
        build_command += ["--identity", args.identity]
    if args.keychain:
        build_command += ["--keychain", args.keychain]
    step("build", lambda: run(*build_command))
    app = folder / "Codex Pulse.app"
    artwork = folder / "artwork"
    if args.prepare_only:
        generate_artwork(artwork, candidate=True)
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if "PulseCodexExecutable" in info or info.get("PulseDemoMode"):
        raise ValueError("分发应用不得携带本机 CLI 路径或演示标记")
    if info.get("CFBundleIconFile") != "AppIcon" or not (app / "Contents/Resources/AppIcon.icns").is_file():
        raise ValueError("分发应用缺少正式图标")
    binary = app / "Contents/MacOS/CodexPulse"
    helper = app / "Contents/MacOS/PulseActivityHook"
    app_archs = set(run("lipo", "-archs", binary, capture=True).split())
    helper_archs = set(run("lipo", "-archs", helper, capture=True).split())
    expected = {"arm64", "x86_64"} if args.architecture == "universal" else {args.architecture}
    if app_archs != expected or helper_archs != expected:
        raise ValueError("应用 / helper 的架构与要求不符")
    authentication = ["--keychain-profile", args.notary_profile] if args.notary_profile else []
    if args.keychain:
        authentication += ["--keychain", args.keychain]
    submissions = {}
    if not args.prepare_only:
        upload = folder / "notary-upload.zip"
        step("app-upload", lambda: archive(app, upload))
        step("app-notarized", lambda: notarize(upload, app, authentication, folder, "app"))
        submissions["app"] = json.loads((folder / "app-result.json").read_text())["id"]
        run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    zip_path = folder / (base + "-" + label + ".zip")
    step("zip", lambda: archive(app, zip_path))
    dmg = folder / (base + "-" + label + ".dmg")
    step("dmg", lambda: run(sys.executable, "-m", "dmgbuild", "-s", ROOT / "scripts/dmg_settings.py",
        "-D", "app=" + str(app), "-D", "artwork=" + str(artwork),
        "-D", "layout=" + str(ROOT / "design/distribution/layout.json"),
        "Codex Pulse", dmg))
    verify_disk_image(dmg, notarized=not args.prepare_only)
    if not args.prepare_only:
        step("dmg-signed", lambda: sign(dmg, signing_identity(args.identity, args.keychain), args.keychain, hardened=False))
        step("dmg-notarized", lambda: notarize(dmg, dmg, authentication, folder, "dmg"))
        submissions["dmg"] = json.loads((folder / "dmg-result.json").read_text())["id"]
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg)
    def finish():
        checksums = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (dmg, zip_path)}
        (folder / "SHA256SUMS.txt").write_text("".join(digest + "  " + name + "\n" for name, digest in checksums.items()))
        manifest = {"version": args.version, "build": args.build_number, "architectures": sorted(app_archs),
                    "status": label, "notarized": not args.prepare_only, "submissions": submissions, "sha256": checksums,
                    "sourceCommit": source_commit, "sourceDirty": source_dirty}
        save_json(folder / "release.json", manifest)
        if not args.prepare_only:
            generate_feed(folder)
    step("feed", finish)
    print("分发目录：", folder)
    print("状态：", "准备候选，ad-hoc / 未公证，不是正式分发包" if args.prepare_only else "Developer ID / 公证 / 票据 / Gatekeeper 均通过")
    return folder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true", help="生成明确标注未公证的 ad-hoc 候选，不执行正式分发")
    parser.add_argument("--identity", help="Developer ID Application 名称或 SHA-1")
    parser.add_argument("--notary-profile", help="已在 notarytool 钥匙串保存的配置名，不传密码")
    parser.add_argument("--keychain", help="可选签名及公证钥匙串路径")
    parser.add_argument("--architecture", choices=["arm64", "x86_64", "universal"], default="universal")
    parser.add_argument("--version", default="0.2.2")
    parser.add_argument("--build-number", default="8")
    parser.add_argument("--output-dir", type=pathlib.Path, help="固定目录；中断后使用相同参数恢复")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or not re.fullmatch(r"[1-9]\d*", args.build_number):
        parser.error("version 必须为三段数字，build-number 必须为正整数")
    try:
        package(args)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
