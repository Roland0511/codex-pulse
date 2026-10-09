# Codex Pulse user guide

[简体中文](USAGE.zh-CN.md) · [Home](../README.md)

## Install and connect

Download the Universal DMG or ZIP from [Releases](https://github.com/Roland0511/codex-pulse/releases/latest). Drag the app to Applications, eject the DMG, then launch. Quit an older instance before replacing it. The app supports macOS 14+, with Apple Silicon runtime verification and Intel compilation coverage.

Install and sign in to the official Codex app or CLI first. Pulse discovers the official desktop bundle and common CLI locations. If discovery fails, open Settings → Codex executable → Choose. The release does not require Python, Xcode, or this repository.

## Read the capsule

The smallest remaining percentage among available windows is shown. Click to inspect every returned window, its actual duration, reset time, available reset count when provided, and the latest successful update. Primary and secondary slots are not assumed to have fixed durations. Unknown values stay unknown.

A connection failure retains the last successful value with an error label. A snapshot older than three minutes is marked out of date. Account changes clear old data. Reset countdowns do not prove that quota has recovered; recovery requires a new service response.

Visible quota refreshes every 60 seconds; explicitly hidden quota every five minutes. Opening details refreshes only if the last success is over 15 seconds old. The app pauses for screen lock or sleep and refreshes on resume. It uses bounded retries and a short-lived local App Server, not inference tasks.

## Move, pin, and use the keyboard

Drag the capsule to either edge to dock it. Hover to expand the bar; the pin keeps it expanded after the pointer leaves. Click for details. The menu's Position commands provide a non-drag alternative.

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
