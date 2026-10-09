#!/usr/bin/env python3
"""准备 / 安装 / 移除只读工作状态 hooks；从不修改 Codex 的信任记录。"""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EVENTS = ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PermissionRequest", "Stop", "Interrupt", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact")
DESCRIPTION = "Codex Pulse 只读工作状态：不读取聊天记录，不输出或改变会话上下文。"


def private_directory(path):
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("目录必须属于当前用户且权限为 0700；未进行修改。")


def definition(helper):
    return {"description": DESCRIPTION, "hooks": {
        event: [{"hooks": [{"type": "command", "command": f"{shlex.quote(str(helper))} --event {event}",
                           "async": True, "timeout": 2}]}] for event in EVENTS}}


def owned(handler, helper):
    if handler.get("type") != "command" or not isinstance(handler.get("command"), str):
        return False
    try:
        args = shlex.split(handler["command"])
    except ValueError:
        return False
    return len(args) == 3 and args[0] == str(helper) and args[1] == "--event" and args[2] in EVENTS


def merged(root, helper, install):
    if not isinstance(root, dict) or not isinstance(root.get("hooks", {}), dict):
        raise ValueError("现有 hooks.json 结构无法安全合并，未修改。")
    result = dict(root)
    hooks = {}
    for event, groups in root.get("hooks", {}).items():
        if not isinstance(groups, list):
            raise ValueError("现有 matcher 组格式无效，未修改。")
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("现有 handler 组格式无效，未修改。")
            if not all(isinstance(item, dict) for item in group["hooks"]):
                raise ValueError("现有 handler 格式无效，未修改。")
            handlers = [item for item in group["hooks"] if not owned(item, helper)]
            if handlers or not group["hooks"]:
                kept.append({**group, "hooks": handlers})
        if kept:
            hooks[event] = kept
    if install:
        for event, groups in definition(helper)["hooks"].items():
            hooks.setdefault(event, []).extend(groups)
    result["hooks"] = hooks
    return result


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("hooks.json 存在重复键，未修改。")
        result[key] = value
    return result


def read_current(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 4 * 1024 * 1024:
            raise ValueError("hooks.json 归属或大小异常，未修改。")
        return file.read()


def atomic_write(path, data, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix=".pulse-stage-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            os.fchmod(file.fileno(), mode)
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def change(hooks_path, support, install, source=None):
    private_directory(support)
    helper = support / "PulseActivityHook"
    hooks_path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(hooks_path.parent / ".pulse-hooks.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original = read_current(hooks_path)
        root = json.loads(original, object_pairs_hook=unique_object) if original is not None else {"description": DESCRIPTION}
        next_root = merged(root, helper, install)
        data = (json.dumps(next_root, ensure_ascii=False, indent=2) + "\n").encode()
        if next_root == root and not install:
            return
        if install:
            if source is None:
                raise ValueError("缺少已验证的 helper，未修改。")
            subprocess.run(["codesign", "--verify", "--strict", str(source)], check=True, capture_output=True)
        backups = support / "hook-backups"
        private_directory(backups)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        if original is not None:
            atomic_write(backups / (stamp + ".json"), original)
        else:
            atomic_write(backups / (stamp + ".absent"), b"hooks.json did not exist before installation.\n")
        if read_current(hooks_path) != original:
            raise ValueError("hooks.json 已被其它程序修改，本次未覆盖。")
        if install:
            if helper.exists() or helper.is_symlink():
                info = helper.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                    raise ValueError("现有 helper 归属异常，未覆盖。")
                atomic_write(backups / (stamp + ".helper"), helper.read_bytes(), mode=0o700)
            atomic_write(helper, source.read_bytes(), mode=0o700)
        if read_current(hooks_path) != original:
            raise ValueError("hooks.json 已被其它程序修改，本次未覆盖。")
        atomic_write(hooks_path, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "install", "remove"])
    args = parser.parse_args()
    support = Path.home() / "Library/Application Support/CodexPulse"
    helper = support / "PulseActivityHook"
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    if args.action == "prepare":
        output = ROOT / "dist/activity-hooks.json"
        output.parent.mkdir(exist_ok=True)
        atomic_write(output, (json.dumps(definition(helper), ensure_ascii=False, indent=2) + "\n").encode())
        print("待审阅的新增定义：", output)
        print("目标：", home / "hooks.json")
        print("prepare 未修改 Codex 配置或信任记录。")
    else:
        source = ROOT / "dist/Codex Pulse.app/Contents/MacOS/PulseActivityHook"
        change(home / "hooks.json", support, args.action == "install", source)
        print("已安装，需在 Codex /hooks 审阅并信任。" if args.action == "install" else "已移除 Pulse 的 handlers；其它 hooks 和信任记录保留。")


if __name__ == "__main__":
    main()
