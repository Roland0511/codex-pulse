#!/usr/bin/env python3
"""构建本地 .app；支持便携通用架构及 Developer ID 签名，不安装或公证。"""
import argparse
import datetime
import os
import pathlib
import plistlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def signing_identity(requested, keychain=None):
    command = ["security", "find-identity", "-v", "-p", "codesigning"]
    if keychain:
        command.append(keychain)
    output = subprocess.check_output(command, text=True)
    matches = [(digest, name) for digest, name in re.findall(r'([A-Fa-f0-9]{40}) "([^"]+)"', output)
               if (digest.lower() == requested.lower() or name == requested)
               and name.startswith("Developer ID Application:")]
    if len(matches) != 1:
        raise ValueError("未找到唯一有效的 Developer ID Application 身份；需要证书及对应私钥，不能使用开发 / ad-hoc 证书替代。")
    return matches[0][0]


def sign(path, identity=None, keychain=None, hardened=True):
    command = ["codesign", "--force", "--sign", identity or "-"]
    if identity:
        command += ["--timestamp"]
        if hardened:
            command += ["--options", "runtime"]
    if keychain:
        command += ["--keychain", keychain]
    subprocess.run(command + [str(path)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)


def build(args):
    identity = signing_identity(args.identity, args.keychain) if args.identity else None
    subprocess.run(["python3", "scripts/generate_tokens.py", "--check"], cwd=ROOT, check=True)
    architectures = ["arm64", "x86_64"] if args.architecture == "universal" else [args.architecture]
    bins = []
    for architecture in architectures:
        command = ["swift", "build", "-c", "release"]
        if architecture != "native":
            command += ["--triple", architecture + "-apple-macosx14.0", "--scratch-path", ".build/distribution-" + architecture]
        subprocess.run(command, cwd=ROOT, check=True)
        bins.append(pathlib.Path(subprocess.check_output(command + ["--show-bin-path"], cwd=ROOT, text=True).strip()))
    dist = args.output_dir.resolve()
    dist.mkdir(parents=True, exist_ok=True)
    app = dist / "Codex Pulse.app"
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    stage = dist / ("stage-" + stamp + ".app")
    macos = stage / "Contents/MacOS"
    macos.mkdir(parents=True)
    for name in ("CodexPulse", "PulseActivityHook"):
        target = macos / name
        if len(bins) == 1:
            shutil.copy2(bins[0] / name, target)
        else:
            subprocess.run(["lipo", "-create", *[str(folder / name) for folder in bins], "-output", str(target)], check=True)
        if args.portable or identity:
            subprocess.run(["strip", "-S", str(target)], check=True)
        subprocess.run(["lipo", "-archs", str(target)], check=True)
    info = {
        "CFBundleExecutable": "CodexPulse", "CFBundleIdentifier": "dev.roland.codex-pulse",
        "CFBundleName": "Codex Pulse", "CFBundleDisplayName": "Codex Pulse",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": args.version, "CFBundleVersion": args.build_number,
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
    }
    # 正式签名和便携候选都不携带开发者机器的 CLI 路径或偏好。
    if not (args.portable or identity) and (executable := shutil.which("codex")):
        info["PulseCodexExecutable"] = os.path.realpath(executable) if os.path.basename(os.path.realpath(executable)) == "codex" else executable
    with (stage / "Contents/Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    sign(macos / "PulseActivityHook", identity, args.keychain)
    sign(stage, identity, args.keychain)
    if app.exists():
        app.rename(dist / ("previous-" + stamp + ".app"))
    stage.rename(app)
    print("应用：", app)
    print("签名：", "Developer ID / Hardened Runtime / 安全时间戳（尚需公证）" if identity else "ad-hoc（非正式分发包）")
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", help="有效 Developer ID Application 证书名称或 SHA-1；不接受开发证书")
    parser.add_argument("--keychain", help="可选签名钥匙串路径，不包含密码")
    parser.add_argument("--architecture", choices=["native", "arm64", "x86_64", "universal"], default="native")
    parser.add_argument("--portable", action="store_true", help="不写入本机 CLI 路径；正式签名时自动生效")
    parser.add_argument("--output-dir", type=pathlib.Path, default=ROOT / "dist")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--build-number", default="1")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or not re.fullmatch(r"[1-9]\d*", args.build_number):
        parser.error("version 必须为三段数字，build-number 必须为正整数")
    if args.keychain and not args.identity:
        parser.error("--keychain 需要 --identity")
    try:
        build(args)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
