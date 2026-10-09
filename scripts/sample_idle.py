#!/usr/bin/env python3
"""采样已有本地实例，不启动推理、不修改系统；只保存 PID/CPU/RSS/计数。"""
import argparse
import datetime
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--seconds", type=int, default=600)
parser.add_argument("--interval", type=int, default=10)
parser.add_argument("--diagnostics", default="private-evidence/runtime.json")
parser.add_argument("--output", default="private-evidence/idle.json")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
target = pathlib.Path(args.output).resolve()
if not target.is_relative_to(root / "private-evidence"):
    parser.error("机器采样必须写入 private-evidence/")
rows = []
start = time.monotonic()
initial = None
def processes():
    text = subprocess.check_output(["ps", "-axo", "pid=,ppid=,%cpu=,rss=,time="], text=True)
    result = {}
    for line in text.splitlines():
        pid, ppid, cpu, rss, cpu_time = line.split()
        fields = cpu_time.split(":")
        seconds = sum(float(v) * 60 ** i for i, v in enumerate(reversed(fields)))
        result[int(pid)] = {"pid": int(pid), "ppid": int(ppid), "cpuPercent": float(cpu), "rssKiB": int(rss), "cpuSeconds": seconds}
    return result
while True:
    all_processes = processes()
    if args.pid not in all_processes:
        raise SystemExit("应用已退出，采样未完成")
    owned = {args.pid}
    for _ in range(8):
        owned |= {pid for pid, p in all_processes.items() if p["ppid"] in owned}
    row = {"elapsedSeconds": time.monotonic() - start,
           "processes": [all_processes[pid] for pid in sorted(owned)]}
    try:
        diagnostic = json.loads(pathlib.Path(args.diagnostics).read_text())
        row["requestCount"] = diagnostic["requestCount"]
        row["quotaReadCount"] = diagnostic["quotaReadCount"]
        for key in ("working", "suspended", "lastActivityEvent"):
            if key in diagnostic:
                row[key] = diagnostic[key]
    except (OSError, KeyError, json.JSONDecodeError):
        pass
    rows.append(row)
    target.parent.mkdir(mode=0o700, exist_ok=True)
    report = {"startedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat() if initial is None else initial,
              "durationSeconds": row["elapsedSeconds"], "appPID": args.pid, "rows": rows}
    initial = report["startedAtUTC"]
    target.write_text(json.dumps(report, indent=2) + "\n"); target.chmod(0o600)
    if row["elapsedSeconds"] >= args.seconds:
        print(json.dumps({"durationSeconds": row["elapsedSeconds"], "samples": len(rows), "output": str(target)}))
        break
    time.sleep(min(args.interval, args.seconds - row["elapsedSeconds"]))
