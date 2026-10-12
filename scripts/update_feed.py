#!/usr/bin/env python3
"""生成带 Ed25519 签名的 Sparkle 更新清单；私钥仅通过系统钥匙串使用。"""
import argparse
import base64
import datetime
import hashlib
import json
import re
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

from build_app import ROOT, update_configuration

ACCOUNT = "dev.roland.codex-pulse"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def tool(name):
    for scratch in (ROOT / ".build", ROOT / ".build/distribution-arm64", ROOT / ".build/distribution-x86_64"):
        path = scratch / "artifacts/sparkle/Sparkle/bin" / name
        if path.is_file():
            return path
    raise ValueError("缺少 Sparkle 工具；请先构建应用")


def verify_key(account=ACCOUNT):
    public = subprocess.check_output([str(tool("generate_keys")), "--account", account, "-p"], text=True).strip()
    if public != update_configuration()["publicEDKey"]:
        raise ValueError("钥匙串更新公钥与应用配置不一致；不能发布")


def make_xml(version, build, archive_name, size, signature, description, now=None):
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("更新签名长度不正确")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdigit() or int(build) < 1 or size <= 0:
        raise ValueError("更新元数据不完整")
    if Path(archive_name).name != archive_name or not archive_name.endswith(".zip"):
        raise ValueError("更新文件必须是发布目录中的 ZIP")
    base = "https://github.com/Roland0511/codex-pulse/releases"
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Codex Pulse"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Codex Pulse " + version
    ET.SubElement(item, "link").text = base + "/tag/v" + version
    ET.SubElement(item, "{" + SPARKLE + "}version").text = build
    ET.SubElement(item, "{" + SPARKLE + "}shortVersionString").text = version
    ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = "14.0.0"
    stamp = now or datetime.datetime.now(datetime.timezone.utc)
    ET.SubElement(item, "pubDate").text = stamp.strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, "description", {"{" + SPARKLE + "}format": "plain-text"}).text = description
    ET.SubElement(item, "enclosure", {
        "url": base + "/download/v" + version + "/" + archive_name,
        "type": "application/octet-stream", "length": str(size),
        "{" + SPARKLE + "}edSignature": signature,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def generate(folder, account=ACCOUNT):
    folder = Path(folder)
    manifest = json.loads((folder / "release.json").read_text())
    if not manifest.get("notarized") or manifest.get("sourceDirty"):
        raise ValueError("仅允许为干净源码的正式公证包生成更新清单")
    verify_key(account)
    name = f'CodexPulse-{manifest["version"]}-universal-notarized.zip'
    archive = folder / name
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if manifest["sha256"].get(name) != digest:
        raise ValueError("ZIP 与发布校验值不一致")
    signer = str(tool("sign_update"))
    signature = subprocess.check_output([signer, "--account", account, "-p", str(archive)], text=True).strip()
    subprocess.run([signer, "--account", account, "--verify", str(archive), signature], check=True)
    feed = folder / "appcast.xml"
    feed.write_bytes(make_xml(manifest["version"], manifest["build"], name, archive.stat().st_size, signature,
        "Codex Pulse " + manifest["version"] + "\n完整更新说明 / Release notes: "
        + "https://github.com/Roland0511/codex-pulse/releases/tag/v" + manifest["version"]))
    subprocess.run([signer, "--account", account, str(feed)], check=True)
    subprocess.run([signer, "--account", account, "--verify", str(feed)], check=True)
    manifest["sha256"]["appcast.xml"] = hashlib.sha256(feed.read_bytes()).hexdigest()
    manifest["updateSignature"] = signature
    manifest["signedFeed"] = True
    (folder / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (folder / "SHA256SUMS.txt").write_text("".join(h + "  " + n + "\n" for n, h in manifest["sha256"].items()))
    return feed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--account", default=ACCOUNT)
    args = parser.parse_args()
    print(generate(args.folder, args.account))
