#!/usr/bin/env python3
"""最小只读探测：不读取认证文件，不创建线程；真实响应只在内存中。"""
import argparse
import datetime
import json
import pathlib
import selectors
import shutil
import subprocess
import time


def probe(executable):
    proc = subprocess.Popen([executable, "app-server", "--listen", "stdio://",
                             "-c", "analytics.enabled=false"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    methods, buffer = [], b""

    def send(method, params=None, request_id=None):
        message = {"method": method}
        if params is not None:
            message["params"] = params
        if request_id is not None:
            message["id"] = request_id
        methods.append(method)
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()

    def read(request_id):
        nonlocal buffer
        deadline = time.monotonic() + 25
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
            import os
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("App Server 已关闭连接")
            buffer += chunk
        raise TimeoutError("只读探测超时")

    try:
        send("initialize", {"clientInfo": {"name": "codex_pulse", "title": "Codex Pulse", "version": "0.1.0"}}, 0)
        read(0)
        send("initialized", {})
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
        return {"sampledAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "cliVersion": subprocess.check_output([executable, "--version"], text=True).strip(),
                "methods": methods, "authenticated": True, "source": source,
                "windows": windows,
                "availableResetCount": (quota.get("rateLimitResetCredits") or {}).get("availableCount"),
                "childPID": proc.pid}
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--private-output", default="private-evidence/probe.json")
    args = parser.parse_args()
    target = pathlib.Path(args.private_output).resolve()
    root = pathlib.Path(__file__).resolve().parents[1]
    if not target.is_relative_to(root / "private-evidence"):
        parser.error("真实快照必须写入仓库 private-evidence/ 下")
    result = probe(args.codex)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    target.write_text(json.dumps(result, indent=2) + "\n")
    target.chmod(0o600)
    print(json.dumps({"authenticated": result["authenticated"], "source": result["source"],
                      "windowCount": len(result["windows"]), "methods": result["methods"],
                      "privateEvidence": str(target), "childReaped": True}, ensure_ascii=False))
