#!/usr/bin/env python3
"""最小只读探测：不读取认证文件，不创建线程；真实响应只在内存中。"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import selectors
import shutil
import subprocess
import time
import tempfile


def server_arguments(runtime, sqlite_directory=None):
    catalog = pathlib.Path(__file__).resolve().parents[1] / "Sources/PulseCore/Resources/QuotaModelCatalog.json"
    local_catalog = pathlib.Path(runtime) / "models.json"
    shutil.copyfile(catalog, local_catalog)
    local_catalog.chmod(0o600)
    return ["app-server", "--listen", "stdio://", "--strict-config",
            "-c", "analytics.enabled=false",
            "-c", "model_catalog_json=" + json.dumps(str(local_catalog), ensure_ascii=False),
            "-c", "sqlite_home=" + json.dumps(str(sqlite_directory or runtime), ensure_ascii=False),
            "-c", "log_dir=" + json.dumps(str(pathlib.Path(runtime) / "log"), ensure_ascii=False)]


def native_executable(executable):
    resolved = pathlib.Path(executable).resolve()
    if resolved.name == "codex.js":
        root = resolved.parent.parent
        architecture, triple = ("arm64", "aarch64") if platform.machine() == "arm64" else ("x64", "x86_64")
        suffix = pathlib.Path(f"@openai/codex-darwin-{architecture}/vendor/{triple}-apple-darwin/bin/codex")
        for candidate in (root / "node_modules" / suffix, root.parent.parent / suffix,
                          root / f"vendor/{triple}-apple-darwin/bin/codex"):
            if os.access(candidate, os.X_OK):
                return str(candidate)
    return str(executable)


def state_directory(executable, environment, state_root=None):
    home = pathlib.Path(environment.get("CODEX_HOME", pathlib.Path.home() / ".codex")).resolve()
    key = hashlib.sha256((str(home) + "\n" + str(pathlib.Path(native_executable(executable)).resolve())).encode()).hexdigest()
    requested = pathlib.Path(state_root) if state_root else pathlib.Path.home() / "Library/Application Support/CodexPulse/QuotaState/v1"
    root = requested.parent.resolve() / requested.name
    for directory in (root, root / key):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if directory.is_symlink() or not directory.is_dir() or directory.stat().st_uid != os.getuid():
            raise RuntimeError("Pulse 数据库目录必须是当前用户拥有的真实目录")
        directory.chmod(0o700)
    return root / key


def probe(executable, environment=None, observation_seconds=0, state_root=None,
          initialization_timeout=120, request_timeout=20, inspect_hooks=False):
    child_environment = dict(os.environ if environment is None else environment)
    executable = native_executable(executable)
    database = state_directory(executable, child_environment, state_root)
    deadline = time.monotonic() + initialization_timeout
    descriptor = os.open(database / "runtime.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("等待 Pulse 数据库超时")
                time.sleep(0.1)
        with tempfile.TemporaryDirectory(prefix="codex-pulse-probe-") as runtime:
            child_environment["CODEX_SQLITE_HOME"] = str(database)
            return _probe(executable, server_arguments(runtime, database), child_environment, observation_seconds,
                          initialization_timeout=max(0, deadline - time.monotonic()),
                          request_timeout=request_timeout, inspect_hooks=inspect_hooks)
    finally:
        os.close(descriptor)


def _probe(executable, arguments, environment=None, observation_seconds=0,
           initialization_timeout=120, request_timeout=20, inspect_hooks=False):
    proc = subprocess.Popen([executable, *arguments], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    methods, buffer, timings = [], b"", {}

    def send(method, params=None, request_id=None):
        message = {"method": method}
        if params is not None:
            message["params"] = params
        if request_id is not None:
            message["id"] = request_id
        methods.append(method)
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()

    def read(request_id, timeout=request_timeout):
        nonlocal buffer
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                obj = json.loads(line)
                if obj.get("id") == request_id:
                    if "error" in obj:
                        raise RuntimeError("只读请求失败，RPC code=" + str(obj["error"].get("code")))
                    return obj["result"]
            if not sel.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("App Server 已关闭连接")
            buffer += chunk
        raise TimeoutError("只读探测超时")

    try:
        params = {"clientInfo": {"name": "codex_pulse", "title": "Codex Pulse", "version": "0.1.0"}}
        if inspect_hooks:
            params["capabilities"] = {"experimentalApi": True}
        started = time.monotonic()
        send("initialize", params, 0)
        read(0, initialization_timeout)
        timings["initializeSeconds"] = round(time.monotonic() - started, 3)
        send("initialized", {})
        hook_counts = None
        if inspect_hooks:
            send("hooks/list", {"cwds": [str(pathlib.Path.home())]}, 3)
            hooks = read(3)
            # 不保存 hooks 定义；输出仅含数量，便于人工与应用核对。
            selected = [hook for entry in hooks.get("data", []) for hook in entry.get("hooks", [])
                        if "PulseActivityHook" in hook.get("command", "")]
            hook_counts = {"found": len(selected), "enabled": sum(h.get("enabled") is True for h in selected),
                           "trusted": sum(h.get("trustStatus") in ("trusted", "managed") for h in selected)}
        send("account/read", {"refreshToken": False}, 1)
        account = read(1).get("account")
        if not account:
            raise RuntimeError("尚未登录")
        send("account/rateLimits/read", None, 2)
        quota = read(2)
        buckets = quota.get("rateLimitsByLimitId")
        source = "multi" if isinstance(buckets, dict) else "legacy"
        if not isinstance(buckets, dict):
            buckets = {"legacy": quota.get("rateLimits", {})}
        windows = []
        for index, (_, bucket) in enumerate(sorted(buckets.items())):
            for slot in ("primary", "secondary"):
                window = bucket.get(slot)
                if isinstance(window, dict):
                    windows.append({"bucket": index, "slot": slot, "windowDurationMins": window.get("windowDurationMins"),
                                    "usedPercent": window.get("usedPercent"), "resetsAt": window.get("resetsAt")})
        # 真实值只写到调用者明确指定、被 Git 忽略的本地证据文件。
        result = {"sampledAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "cliVersion": subprocess.check_output([executable, "--version"], text=True, env=environment).strip(),
                "methods": methods, "authenticated": True, "source": source,
                "windows": windows,
                "availableResetCount": (quota.get("rateLimitResetCredits") or {}).get("availableCount"),
                "childPID": proc.pid}
        result.update(timings)
        if inspect_hooks:
            result["hookCounts"] = hook_counts
        # 隔离回归可保留连接，观察启动后的后台目录刷新；正常探测不等待。
        if observation_seconds:
            time.sleep(observation_seconds)
        return result
    finally:
        proc.stdin.close()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        sel.close()
        proc.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--private-output", default="private-evidence/probe.json")
    parser.add_argument("--state-root", help="隔离测试用数据库根目录；默认与应用共用私有状态目录")
    args = parser.parse_args()
    target = pathlib.Path(args.private_output).resolve()
    root = pathlib.Path(__file__).resolve().parents[1]
    if not target.is_relative_to(root / "private-evidence"):
        parser.error("真实快照必须写入仓库 private-evidence/ 下")
    result = probe(args.codex, state_root=args.state_root)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    target.write_text(json.dumps(result, indent=2) + "\n")
    target.chmod(0o600)
    print(json.dumps({"authenticated": result["authenticated"], "source": result["source"],
                      "windowCount": len(result["windows"]), "methods": result["methods"],
                      "privateEvidence": str(target), "childReaped": True}, ensure_ascii=False))
