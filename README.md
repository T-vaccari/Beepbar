# Beepbar

[![CI](https://github.com/T-vaccari/Beepbar/actions/workflows/ci.yml/badge.svg)](https://github.com/T-vaccari/Beepbar/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/T-vaccari/Beepbar?include_prereleases&label=release)](https://github.com/T-vaccari/Beepbar/releases/tag/v0.1.0-beta.1)
[![Downloads](https://img.shields.io/github/downloads/T-vaccari/Beepbar/total)](https://github.com/T-vaccari/Beepbar/releases)

A native macOS app for syncing WeBeep materials locally. Beepbar is built specifically for Apple Silicon, stays lightweight in the background, and protects local changes instead of blindly replacing them with remote files.

## TL;DR / Install

1. [Download Beepbar.dmg](https://github.com/T-vaccari/Beepbar/releases/download/v0.1.0-beta.1/Beepbar.dmg), double-click it, then drag Beepbar into Applications.
2. On first launch, right-click Beepbar and choose **Open**. If macOS blocks it, go to **System Settings > Privacy & Security** and choose **Open Anyway**.
3. Open Beepbar from the menu bar, sign in to WeBeep in the browser, and choose the local sync folder.

`Beepbar.dmg` is ad-hoc signed so macOS can verify its integrity, but it is not Developer ID signed or notarized because this project does not use an Apple Developer account. The initial Gatekeeper step is therefore expected. If it still blocks the app after moving it into Applications, use this fallback:

```sh
xattr -dr com.apple.quarantine /Applications/Beepbar.app
```

## Features

- Menu-bar app with clear sync status and contextual actions
- Browser-based WeBeep login, with the token stored in the macOS Keychain
- Manual or configurable automatic sync
- Controlled parallel downloads, byte-level progress, and real cancellation
- Selectable sync root and editable course-folder names
- Three-way sync backed by SQLite, atomic staging, and explicit conflict resolution

## Why Beepbar

I wanted something built specifically for macOS: a small app that stays in the menu bar, does not keep a window open, and avoids aggressive background polling. It should be responsive when I need it and quiet when I leave it running throughout the day.

Imagine modifying or annotating a PDF after Beepbar downloads it. If WeBeep later publishes a newer version, a simple mirror can replace your local file. Beepbar detects that both versions changed, preserves them separately, and lets you decide whether to keep your copy or use the remote one.

In a preliminary local measurement of the Release build, with automatic sync disabled, Beepbar stayed around 14–15 MiB of memory for 30 minutes with effectively idle CPU use. This is a development reference, not a universal guarantee.

## Requirements

- macOS 14 or later
- Apple Silicon

## Development

```sh
swift test
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO
scripts/create-dmg.sh build/Release/Beepbar.app build/Beepbar.dmg
```

CI runs the tests and builds an ad-hoc-signed arm64 DMG.

Beepbar is not affiliated with Politecnico di Milano or WeBeep.
