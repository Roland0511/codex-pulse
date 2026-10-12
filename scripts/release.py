#!/usr/bin/env python3
"""一条命令完成本机签名、公证、草稿校验、公开发布及自动更新清单同步。"""
import argparse
import contextlib
import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from build_app import ROOT, signing_identity
from package_release import save_json
from update_feed import ACCOUNT, SPARKLE, tool, verify_key
from verify_release import REPO, asset_names, digest, require, run, verify, verify_downloads


@contextlib.contextmanager
def release_lock():
    directory = ROOT / "dist/releases"
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".release.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("已有发布进程正在运行") from None
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def remote_release(tag):
    result = subprocess.run(["gh", "api", f"repos/{REPO}/releases/tags/{tag}"], cwd=ROOT,
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        if "HTTP 404" in result.stderr:
            return None
        raise RuntimeError("无法读取发行状态：" + result.stderr.strip())
    data = json.loads(result.stdout)
    return {"id": data["id"], "tagName": data["tag_name"], "isDraft": data["draft"],
            "isPrerelease": data["prerelease"], "url": data["html_url"], "body": data["body"],
            "assets": [{"name": asset["name"], "size": asset["size"], "url": asset["browser_download_url"]} for asset in data["assets"]]}


def check_source(source):
    require(not run("git", "status", "--porcelain").strip(), "发布要求干净工作区，请先提交修改")
    require(run("git", "rev-parse", "HEAD").strip() == source, "构建过程中源码提交变化")
    origin = run("git", "remote", "get-url", "origin").strip()
    require(origin in (f"git@github.com:{REPO}.git", f"https://github.com/{REPO}.git", f"https://github.com/{REPO}"), "origin 不是正式仓库")
    run("git", "fetch", "origin", "main")
    run("git", "merge-base", "--is-ancestor", source, "origin/main")
    runs = json.loads(run("gh", "run", "list", "--repo", REPO, "--workflow", "checks.yml", "--commit", source,
                          "--limit", "20", "--json", "headSha,status,conclusion,event,createdAt"))
    # 必须是受信任 main push 的最新结果，PR 上较早一次成功不能掩盖之后失败。
    trusted = [item for item in runs if item["headSha"] == source and item["event"] == "push"]
    trusted.sort(key=lambda item: item["createdAt"], reverse=True)
    require(trusted and trusted[0]["status"] == "completed" and trusted[0]["conclusion"] == "success", "该源码的 main push Checks 尚未成功")


def check_newer(version, build):
    latest = json.loads(run("gh", "api", f"repos/{REPO}/releases/latest"))
    latest_tag = latest["tag_name"]
    require(re.fullmatch(r"v\d+\.\d+\.\d+", latest_tag), "当前正式版本格式不明确，停止发布")
    require(tuple(map(int, version.split("."))) > tuple(map(int, latest_tag[1:].split("."))), "显示版本必须高于当前正式版本")
    with tempfile.TemporaryDirectory(prefix="pulse-latest-") as temporary:
        run("gh", "release", "download", latest_tag, "--repo", REPO, "--pattern", "appcast.xml", "--dir", temporary)
        feed = pathlib.Path(temporary) / "appcast.xml"
        run(tool("sign_update"), "--account", ACCOUNT, "--verify", feed)
        items = ET.parse(feed).findall("channel/item")
        require(items, "当前正式清单没有版本")
        builds = [int(item.findtext("{" + SPARKLE + "}version")) for item in items]
        require(int(build) > max(builds), "build 必须高于正式清单中的全部版本")
    return latest_tag


def verify_tag(tag, source):
    require(run("git", "rev-parse", tag + "^{commit}").strip() == source, "tag 不指向本次源码")
    if run("git", "config", "--get", "--default", "openpgp", "gpg.format").strip() == "ssh":
        key = run("git", "config", "--get", "user.signingkey").strip()
        if key.startswith("key::"):
            key = key[5:]
        if not key.startswith(("ssh-", "ecdsa-")):
            key = pathlib.Path(key).expanduser().read_text().strip()
        require("PRIVATE KEY" not in key, "user.signingkey 必须引用公钥")
        with tempfile.TemporaryDirectory(prefix="pulse-tag-") as temporary:
            allowed = pathlib.Path(temporary) / "allowed-signers"
            allowed.write_text("* " + key + "\n")
            run("git", "-c", "gpg.ssh.allowedSignersFile=" + str(allowed), "verify-tag", tag)
    else:
        run("git", "verify-tag", tag)


def ensure_tag(tag, source):
    remote = run("git", "ls-remote", "--tags", "origin", "refs/tags/" + tag).strip()
    if remote:
        run("git", "fetch", "origin", "refs/tags/" + tag + ":refs/tags/" + tag)
    elif not run("git", "tag", "--list", tag).strip():
        run("git", "tag", "-s", tag, source, "-m", "Codex Pulse " + tag, timeout=180)
    verify_tag(tag, source)
    if not remote:
        run("git", "push", "origin", "refs/tags/" + tag, timeout=180)


def publish_assets(folder, tag, source, notes, journal, state_path, before_publish):
    """所有上传只发生在草稿；失败保留草稿，重试不覆盖已有附件。"""
    def save():
        save_json(state_path, journal)
    remote = remote_release(tag)
    if remote is not None:
        require(journal.get("createStarted"), "发行已存在且不属于本次流程，拒绝接管")
        require(remote["body"] == notes.read_text(), "发行说明被修改，停止发布")
        require(not remote["isPrerelease"], "不支持接管预发行")
        if "releaseId" in journal:
            require(remote["id"] == journal["releaseId"], "发行 ID 变化")
        if not remote["isDraft"]:
            require(journal.get("publishStarted"), "发行已由其他路径公开，拒绝修改")
            verify_downloads(folder, remote, public=True)
            journal["complete"] = True
            save()
            return remote["url"]
    else:
        require("releaseId" not in journal, "原发行已被删除，拒绝自动重建")
        journal["createStarted"] = True
        save()
        run("gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--draft", "--title", "Codex Pulse " + tag, "--notes-file", notes)
        remote = remote_release(tag)
    require(remote is not None and remote["isDraft"], "无法确认草稿创建成功")
    journal["releaseId"] = remote["id"]
    save()
    expected = asset_names(journal["version"])
    existing = {asset["name"] for asset in remote["assets"]}
    require(existing <= expected, "草稿含有非预期附件")
    # 已存在的附件不使用 --clobber；先比对，以便发现外部修改和中断时的不完整上传。
    for asset in remote["assets"]:
        require(asset["size"] == (folder / asset["name"]).stat().st_size, "草稿附件尺寸变化")
        with tempfile.TemporaryDirectory(prefix="pulse-resume-") as temporary:
            run("gh", "release", "download", tag, "--repo", REPO, "--pattern", asset["name"], "--dir", temporary)
            require(digest(pathlib.Path(temporary) / asset["name"]) == digest(folder / asset["name"]), "草稿附件摘要变化")
    for name in sorted(expected - existing):
        run("gh", "release", "upload", tag, folder / name, "--repo", REPO)
    verify_downloads(folder, remote_release(tag))
    before_publish()
    # 公告前再核对草稿，避免耗时检查期间意外新增附件。
    verify_downloads(folder, remote_release(tag))
    journal["publishStarted"] = True
    save()
    run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest", "--verify-tag")
    verify_downloads(folder, remote_release(tag), public=True)
    journal["complete"] = True
    save()
    return remote_release(tag)["url"]


def release(args):
    source = run("git", "rev-parse", "HEAD").strip()
    tag = "v" + args.version
    notes = args.notes_file.resolve()
    require(notes.is_file() and notes.read_text().strip(), "需要非空发行说明文件")
    directory = ROOT / "dist/releases" / (tag + "-build" + args.build_number)
    directory.mkdir(parents=True, exist_ok=True)
    folder = directory / "artifacts"
    state_path = directory / "publish-state.json"
    inputs = {"version": args.version, "build": args.build_number, "source": source,
              "notesSHA256": digest(notes)}
    journal = json.loads(state_path.read_text()) if state_path.exists() else {**inputs}
    require(all(journal.get(key) == value for key, value in inputs.items()), "恢复记录与源码、版本或发行说明不匹配")
    # 存在但不属于恢复记录的发行必须在任何打包或上传之前停止。
    remote = remote_release(tag)
    require(remote is None or journal.get("createStarted"), "此版本已存在，请递增 version 和 build")
    print("核对钥匙串、源码、远端 CI 和当前正式版本…", flush=True)
    check_source(source)
    run("swift", "package", "resolve", timeout=600)
    verify_key()
    signing_identity(args.identity, args.keychain)
    if not (remote and not remote["isDraft"] and journal.get("publishStarted")):
        check_newer(args.version, args.build_number)
    save_json(state_path, journal)
    package_state = folder / "package-state.json"
    packaged = package_state.exists() and "feed" in json.loads(package_state.read_text())["completed"]
    if not packaged:
        print("执行测试与通用架构构建、签名、公证（中断后可使用相同命令恢复）…", flush=True)
        # SwiftPM / App Server 的全部测试不启动真实推理任务。
        run("swift", "test", timeout=1200)
        run(sys.executable, "-m", "unittest", "discover", "-s", "Tests", "-p", "test_*.py", timeout=300)
        run(sys.executable, "scripts/generate_tokens.py", "--check")
        run(sys.executable, "scripts/generate_localizations.py", "--check")
        command = [sys.executable, "scripts/package_release.py", "--version", args.version,
                   "--build-number", args.build_number, "--identity", args.identity,
                   "--notary-profile", args.notary_profile, "--output-dir", folder]
        if args.keychain:
            command += ["--keychain", args.keychain]
        # notarytool 自身每次最多 wait 20 分钟；超时保留提交 ID，再运行同一命令恢复。
        run(*command, timeout=3600)
    print("独立验证签名、公证、安装包与更新清单…", flush=True)
    verify(folder, source)
    check_source(source)
    ensure_tag(tag, source)
    def before_publish():
        require(digest(notes) == journal["notesSHA256"], "发布过程中发行说明发生变化")
        check_source(source)
        check_newer(args.version, args.build_number)
        verify_tag(tag, source)
        verify(folder, source)
    print("创建或恢复草稿，上传并校验附件，通过后公开并检查自动更新地址…", flush=True)
    return publish_assets(folder, tag, source, notes, journal, state_path, before_publish)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--notes-file", required=True, type=pathlib.Path)
    parser.add_argument("--identity", default=os.environ.get("PULSE_SIGNING_IDENTITY"))
    parser.add_argument("--notary-profile", default=os.environ.get("PULSE_NOTARY_PROFILE"))
    parser.add_argument("--keychain", default=os.environ.get("PULSE_SIGNING_KEYCHAIN"))
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or not re.fullmatch(r"[1-9]\d*", args.build_number):
        parser.error("version 必须是三段数字，build-number 必须是正整数")
    if not args.identity or not args.notary_profile:
        parser.error("需要 --identity / PULSE_SIGNING_IDENTITY 和 --notary-profile / PULSE_NOTARY_PROFILE；仅传钥匙串引用，不传密码")
    try:
        with release_lock():
            print("发布完成：" + release(args))
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(((error.stdout or "") + (error.stderr or ""))[-4000:], file=sys.stderr)
        parser.exit(1, str(error) + "\n发布未确认完成。保留 dist/releases 中记录，排除错误后使用完全相同的命令恢复。\n")


if __name__ == "__main__":
    main()
