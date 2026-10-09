#!/usr/bin/env python3
"""可复现的本地 .app 打包；不安装、不公证、不注册开机启动。"""
import datetime
import os
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(["python3", "scripts/generate_tokens.py", "--check"], cwd=root, check=True)
subprocess.run(["swift", "build", "-c", "release"], cwd=root, check=True)
bin_dir = pathlib.Path(subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip())
dist = root / "dist"
dist.mkdir(exist_ok=True)
app = dist / "Codex Pulse.app"
stage = dist / ("stage-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".app")
macos = stage / "Contents/MacOS"
macos.mkdir(parents=True)
shutil.copy2(bin_dir / "CodexPulse", macos / "CodexPulse")
shutil.copy2(bin_dir / "PulseActivityHook", macos / "PulseActivityHook")
subprocess.run(["codesign", "--force", "--sign", "-", str(macos / "PulseActivityHook")], check=True)
info = {
    "CFBundleExecutable": "CodexPulse", "CFBundleIdentifier": "dev.roland.codex-pulse",
    "CFBundleName": "Codex Pulse", "CFBundleDisplayName": "Codex Pulse",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
    "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
}
if executable := shutil.which("codex"):
    info["PulseCodexExecutable"] = os.path.realpath(executable) if os.path.basename(os.path.realpath(executable)) == "codex" else executable
with (stage / "Contents/Info.plist").open("wb") as file:
    plistlib.dump(info, file)
subprocess.run(["codesign", "--force", "--sign", "-", str(stage)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(stage)], check=True)
if app.exists():
    app.rename(dist / ("previous-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".app"))
stage.rename(app)
print("本地应用：", app)
print("签名：ad-hoc（无 Developer ID、未公证）")
