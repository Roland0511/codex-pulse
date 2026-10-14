#!/usr/bin/env python3
"""从唯一参数源生成 Swift；--check 用于检测漂移。"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
t = json.loads((root / "design/v0.1/tokens.json").read_text())
values = {
    "capsuleWidth": t["capsule"]["width"], "height": t["capsule"]["height"],
    "dockedWidth": t["docked"]["width"], "detailsWidth": t["details"]["width"],
    "dockedExpandedWidth": t["docked"]["expandedWidth"],
    "detailsSingleWindowHeight": t["details"]["singleWindowHeight"],
    "detailsPadding": t["details"]["padding"], "detailsSectionSpacing": t["details"]["sectionSpacing"],
    "detailsHeaderHeight": t["details"]["headerHeight"], "detailsRowSpacing": t["details"]["rowSpacing"],
    "joinRadius": t["joinRadius"], "outerRadius": t["outerRadius"],
    "outlineWidth": t["outlineWidth"], "dragThreshold": t["dragThreshold"],
    "attachmentTravel": t["attachmentTravel"], "expandSeconds": t["expandDurationMs"] / 1000,
    "hoverLeaveSeconds": t["hoverLeaveDelayMs"] / 1000, "barSeconds": t["quotaBarDurationMs"] / 1000,
    "recoverySeconds": t["recovery"]["durationMs"] / 1000,
    "consumptionSeconds": t["consumption"]["durationMs"] / 1000,
    "consumptionLaps": t["consumption"]["laps"], "consumptionHeadWidth": t["consumption"]["headWidth"],
    "consumptionFadeInEndFraction": t["consumption"]["fadeInEndFraction"],
    "consumptionFadeOutStartFraction": t["consumption"]["fadeOutStartFraction"],
    "consumptionFadeOutEndFraction": t["consumption"]["fadeOutEndFraction"],
    "peakOutlineWidth": t["recovery"]["peakOutlineWidth"], "peakHoldFraction": t["recovery"]["peakHoldFraction"],
    "percentageOnlyBelowWidth": t["text"]["percentageOnlyBelowWidth"],
    "countdownRevealFrom": t["text"]["countdownRevealFrom"], "countdownRevealTo": t["text"]["countdownRevealTo"]
}
source = "// 由 scripts/generate_tokens.py 生成；请修改 design/v0.1/tokens.json。\nimport Foundation\n\npublic enum DesignTokens {\n"
source += "".join(f"    public static let {key}: Double = {value}\n" for key, value in values.items())
lightning = t["consumption"]["lightning"]
for key in ["effectHeight", "cycleMs", "transitionMs", "subdivisions", "displacementDecay", "temporalDrift", "branchLengthFraction", "compactMaxWidth", "microMaxWidth", "segmentLength", "compactLengthFraction", "compactAmplitude", "compactHaloWidth", "compactGlowRadius", "compactBurstScale", "compactStrokeBoost", "compactOpacityBoost"]:
    suffix = key.replace("Ms", "Seconds")
    value = lightning[key] / 1000 if key.endswith("Ms") else lightning[key]
    source += f"    public static let lightning{suffix[0].upper() + suffix[1:]}: Double = {value}\n"
for tier in ["fast", "ultrafast"]:
    for key, value in lightning[tier].items():
        suffix = key.replace("Ms", "Seconds")
        name = tier + "Lightning" + suffix[0].upper() + suffix[1:]
        if isinstance(value, list):
            source += f"    public static let {name}: [Double] = {json.dumps([v / 1000 for v in value])}\n"
        else:
            value = value / 1000 if key.endswith("Ms") else value
            source += f"    public static let {name}: Double = {value}\n"
for name, variants in lightning["colors"].items():
    for theme, value in variants.items():
        source += f"    public static let lightning{name.capitalize()}{theme.capitalize()}: UInt32 = 0x{value[1:]}\n"
for name, variants in t["colors"].items():
    for theme, value in variants.items():
        source += f"    public static let {name}{theme.capitalize()}: UInt32 = 0x{value[1:]}\n"
source += "    public static let expandCurve: [Double] = " + json.dumps(t["expandCurve"]) + "\n}\n"
target = root / "Sources/PulseCore/DesignTokens.swift"
if "--check" in sys.argv:
    if not target.exists() or target.read_text() != source:
        sys.exit("冻结参数与 Swift 存在漂移")
    print("冻结参数检查通过")
else:
    target.write_text(source)
