# Codex Pulse user guide

[简体中文](USAGE.zh-CN.md) · [Home](../README.md)

## Install and connect

Download and open the Universal DMG from [Releases](https://github.com/Roland0511/codex-pulse/releases/latest). Drag the app to Applications, eject the disk image, then launch. A ZIP is also available. The app and DMG are Developer ID signed, notarized, and stapled; verify your download against `SHA256SUMS.txt`. Quit an older instance before replacing it. The app supports macOS 14+, with Apple Silicon runtime verification and Intel compilation coverage.

Install and sign in to the official Codex app or CLI first. Pulse discovers the official desktop bundle and common CLI locations. If discovery fails, open Settings → Codex executable → Choose. The release does not require Python, Xcode, or this repository.

## Read the capsule

The smallest remaining percentage among available windows is shown. Click to inspect every returned window, its actual duration, reset time, available reset count when provided, and the latest successful update. Primary and secondary slots are not assumed to have fixed durations. Unknown values stay unknown.

When any subscription window is exhausted and the same quota bucket reports a positive credit balance, the capsule displays credits instead. Compact capsules default to one decimal place, such as `60.0k` or `1.2M`; the hover strip and expanded details default to two, such as `60,123.45`. Settings → Credit decimal places lets you choose 0–3 places independently, with changes applied immediately and saved. Values are truncated down and retain trailing zeros; a narrow capsule may use fewer places or abbreviate to fit. Hover text and accessibility descriptions retain the exact original balance. Tiny positive balances display `<0.1` or the corresponding precision threshold rather than zero. The full line in credit mode indicates available credits, not a percentage. Subscription recovery switches the capsule back to percentages after a successful refresh.

A connection failure retains the last successful value with an error label. A snapshot older than three minutes is marked out of date. Account changes clear old data. Reset countdowns do not prove that quota has recovered; recovery requires a new service response.

Visible quota refreshes every 60 seconds; explicitly hidden quota every five minutes. Opening details refreshes only if the last success is over 15 seconds old. The app pauses for screen lock or sleep and refreshes on resume. It uses bounded retries and a short-lived local App Server, not inference tasks.

## Move, pin, and use the keyboard

Drag near either screen edge or either inner edge of a Codex window, then release to attach. When both targets qualify, an Attach to menu lets you choose the screen or Codex window; Escape cancels and leaves the capsule floating. Position also offers four explicit docking commands.

When attached to Codex, the capsule follows its window as it moves or resizes. It hides while Codex is minimized and returns with the window. Switching apps keeps the capsule attached; foreground windows cover both Codex and its capsule. Hover expands the bar, pin keeps it expanded, and a click opens details. Choosing screen docking ends window following.

The default show/hide shortcut is `Control + Option + Command + P`. Settings lets you choose a key and at least two modifiers; conflicts are reported. Use the menu's Show quota details command for keyboard focus, then Escape to close. Mouse-opened details do not steal focus.

## Language and appearance

Settings → Language offers Follow system, 简体中文, and English. Changes take effect immediately and persist. System mode uses Simplified Chinese for Chinese environments and English otherwise. Dates use the selected language, the user's region, and local time zone. Service-provided bucket names remain unchanged.

Appearance follows the Codex theme by default, including its mode, background, foreground, and accent. System, Light, and Dark use Pulse's built-in palette. Unsupported appearance settings fall back to the system theme with an explanation.

## Work animation

This optional feature is off for new installations. Enable it in Settings, review the 12 definitions and destination path, and confirm installation. Pulse preserves other hooks and makes a local backup. Then launch Codex CLI, enter `/hooks`, review and trust every Pulse definition, and choose Check connection in Pulse.

There are 12 definitions because Codex lifecycle events have separate handlers. Most execute asynchronously; session-end handling is synchronous under Codex with a two-second timeout. The helper skips prompts, tool arguments, responses, and other content. Its allowlisted metadata stays on this Mac.

Animation requires all hooks enabled and trusted plus a working receiver. It stops while waiting for permission, when work ends, or if signals become invalid. With multiple sessions it continues while any confirmed session is working. Reduce Motion keeps static status text. A separate brief trace can acknowledge quota consumption confirmed by fresh snapshots.

Turning the feature off removes only Pulse's own handlers. To uninstall cleanly, disable it before quitting and moving the app to Trash. Backups remain local for recovery.

## Optional alerts and login launch

Both are off by default. Low quota alerts request macOS notification permission only when enabled, and deduplicate the 20% / 10% thresholds per cycle. Launch at login may require approval in System Settings → Login Items. Enabled-state system delivery and login behavior remain outside the current real-device acceptance record; see [verification](VERIFICATION.md).

## Report a problem

Include macOS, CPU architecture, Pulse version, Codex version, the visible error, and reproduction steps in [Issues](https://github.com/Roland0511/codex-pulse/issues). Do not attach account responses, authentication files, chat logs, unredacted screenshots, or hook backups. Use [private vulnerability reporting](../SECURITY.md) for security issues.

## Generation speed (TPS)

“Show generation speed (TPS)” is enabled by default in Settings. The docked capsule places quota and speed side by side; disabling it restores the narrow label. Complete the existing activity-hook trust setup first. TPS does not install hooks or change Codex configuration.

Details say “Updates per response” and show the sample time. TPS uses official output tokens divided by local model-item timing intervals, including reasoning output; it is not a token-stream instantaneous or server decode benchmark. `~` marks retained values or a partial sum; individual samples expire after 60 seconds; `···` waits for a complete sample. “Wait” indicates permission waiting. Multiple sessions show Total TPS: the sum of their latest valid response rates, excluding permission waits. Details show contributing / generating sessions and waiting sessions. Missing samples produce an explicitly labeled partial sum; the oldest included response determines freshness. Idle, disconnected, and unavailable timing data never become a false zero. Missing fields or a partial initial tail wait for the next complete sample.

Choose **Compact capsule layout → Side by side / Stacked** in Settings. The choice applies immediately and persists. Side by side uses 104 × 36 pt; Stacked keeps 54 × 36 pt with quota above speed. Hovered and pinned bars remain horizontal. Turning TPS off and back on preserves the layout.
