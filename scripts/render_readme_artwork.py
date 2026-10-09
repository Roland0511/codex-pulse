#!/usr/bin/env python3
"""Editable README illustrations. All displayed quota values are synthetic."""
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
palette = json.loads((ROOT / "design/v0.1/tokens.json").read_text())["colors"]
output = ROOT / "docs/assets"
output.mkdir(exist_ok=True)
for language, copy in {
    "en": ("Small capsule.", "Clearer limits.", "Your Codex quota, always within reach.",
           "Native macOS  ·  Local data  ·  MIT", "Resets in 2h", "Quota remaining",
           "Illustration · synthetic data"),
    "zh": ("额度变化，", "一眼就知道。", "一枚小胶囊，让 Codex 额度随手可见。",
           "macOS 原生  ·  数据留在本机  ·  MIT", "2小时后重置", "剩余额度",
           "产品示意 · 合成数据"),
}.items():
    line1, line2, subtitle, footer, countdown, status, note = map(html.escape, copy)
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="520" viewBox="0 0 1200 520" role="img" aria-labelledby="title desc">
  <title id="title">Codex Pulse</title>
  <desc id="desc">{subtitle} {note}</desc>
  <defs>
    <filter id="shadow" x="-30%" y="-60%" width="160%" height="220%"><feDropShadow dx="0" dy="8" stdDeviation="14" flood-color="#19242b" flood-opacity=".08"/></filter>
  </defs>
  <rect width="1200" height="520" rx="28" fill="{palette['surface']['light']}"/>
  <g font-family="-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC',sans-serif">
    <rect x="64" y="52" width="38" height="38" rx="12" fill="{palette['surface']['dark']}"/>
    <rect x="71" y="66" width="24" height="10" rx="5" fill="none" stroke="{palette['muted']['dark']}" stroke-width="1"/>
    <path d="M75 71h11" stroke="{palette['signal']['dark']}" stroke-width="1.5" stroke-linecap="round"/>
    <text x="116" y="78" fill="{palette['ink']['light']}" font-size="24" font-weight="600">Codex Pulse</text>
    <text x="64" y="214" fill="{palette['ink']['light']}" font-size="52" font-weight="650" letter-spacing="-1.7">{line1}</text>
    <text x="64" y="278" fill="{palette['signal']['light']}" font-size="52" font-weight="650" letter-spacing="-1.7">{line2}</text>
    <text x="64" y="326" fill="{palette['muted']['light']}" font-size="19">{subtitle}</text>
    <text x="64" y="435" fill="{palette['muted']['light']}" font-size="16">{footer}</text>
    <rect x="612" y="64" width="524" height="366" rx="20" fill="#f3f7f7" stroke="{palette['edge']['light']}"/>
    <path d="M612 112h524" stroke="{palette['edge']['light']}"/>
    <circle cx="637" cy="88" r="4" fill="#b9c7ca"/><circle cx="653" cy="88" r="4" fill="#cbd5d7"/><circle cx="669" cy="88" r="4" fill="#dbe4e7"/>
    <path d="M1135 112v298" stroke="{palette['edge']['light']}" stroke-width="2"/>
    <g filter="url(#shadow)">
      <rect x="690" y="180" width="234" height="48" rx="13" fill="{palette['surface']['dark']}"/>
      <rect x="690" y="180" width="234" height="48" rx="13" fill="none" stroke="{palette['edge']['dark']}" stroke-width=".65"/>
      <text x="706" y="209" fill="{palette['ink']['dark']}" font-size="20" font-weight="550">72%</text>
      <text x="759" y="207" fill="{palette['muted']['dark']}" font-size="12">{countdown}</text>
      <rect x="703" y="219" width="208" height="2" rx="1" fill="{palette['track']['dark']}"/>
      <rect x="703" y="219" width="150" height="2" rx="1" fill="{palette['signal']['dark']}"/>
    </g>
    <path d="M807 245v36h249" fill="none" stroke="#c4d2d2" stroke-width="1.2" stroke-dasharray="3 5"/>
    <path d="M1136 266h-59q-12 0-12 12v8q0 12 12 12h59" fill="{palette['surface']['dark']}"/>
    <text x="1080" y="287" fill="{palette['ink']['dark']}" font-size="14" font-weight="550">72%</text>
    <path d="M1075 293h45" stroke="{palette['signal']['dark']}" stroke-width="2" stroke-linecap="round"/>
    <text x="690" y="353" fill="{palette['muted']['light']}" font-size="13">{status}</text>
    <text x="1136" y="478" text-anchor="end" fill="{palette['muted']['light']}" font-size="13">{note}</text>
  </g>
</svg>
'''
    (output / f"hero-{language}.svg").write_text(svg)
