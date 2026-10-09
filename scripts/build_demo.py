#!/usr/bin/env python3
"""建立隔离的合成数据预览包；本工具不启动程序，不读账户。"""
import argparse
import datetime
import pathlib
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("scenario", choices=["normal", "long", "empty", "unknown", "loading", "error", "stale", "logout", "low", "consuming", "working"])
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
source = root / "dist/Codex Pulse.app"
target = root / "dist/Codex Pulse Demo.app"
if target.exists():
    target.rename(target.parent / ("demo-previous-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".app"))
shutil.copytree(source, target)
plist = target / "Contents/Info.plist"
with plist.open("rb") as file:
    info = plistlib.load(file)
info.update({"CFBundleIdentifier": "dev.roland.codex-pulse.demo", "CFBundleName": "Codex Pulse Demo",
             "CFBundleDisplayName": "Codex Pulse Demo", "PulseDemoMode": True, "PulseDemoScenario": args.scenario})
with plist.open("wb") as file:
    plistlib.dump(info, file)
subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
print(target)
