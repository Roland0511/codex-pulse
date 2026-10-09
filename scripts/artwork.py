"""使用原生矢量绘制生成应用图标及安装背景，无第三方绘图依赖。"""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def generate(output, candidate=False):
    output = pathlib.Path(output).resolve()
    subprocess.run(["swift", str(ROOT / "scripts/render_artwork.swift"),
                    str(ROOT / "design/v0.1/tokens.json"),
                    str(ROOT / "design/distribution/layout.json"), str(output),
                    "candidate" if candidate else "release"], check=True)
    subprocess.run(["iconutil", "-c", "icns", str(output / "AppIcon.iconset"),
                    "-o", str(output / "AppIcon.icns")], check=True)
    return output
