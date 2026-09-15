# Beepbar

[![CI](https://github.com/T-vaccari/Beepbar/actions/workflows/ci.yml/badge.svg)](https://github.com/T-vaccari/Beepbar/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/T-vaccari/Beepbar?include_prereleases&label=release)](https://github.com/T-vaccari/Beepbar/releases/tag/latest)
[![Downloads](https://img.shields.io/github/downloads/T-vaccari/Beepbar/total)](https://github.com/T-vaccari/Beepbar/releases)

Has another syncing app ever **overwritten your annotated slides**? Tired of **renaming files** just to stop them from being replaced? Looking for a syncing app that's **super lightweight** and feels **native** to your macOS environment?

Beepbar solves exactly that. It never overwrites your local work: take notes directly on a slide PDF, or edit a file on iPad/Mac after downloading it, and that copy is preserved instead of being silently replaced when WeBeep publishes an update. Built specifically for Apple Silicon, it stays native and ultra-lightweight in the background.

## TL;DR / Install

1. [Download Beepbar.dmg](https://github.com/T-vaccari/Beepbar/releases/download/latest/Beepbar.dmg), double-click it, then drag Beepbar into Applications. This link always points to the build from the latest commit on `main`.
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
- [Three-way sync](#how-the-three-way-sync-works) backed by SQLite, atomic staging, and explicit conflict resolution

## How the three-way sync works

Beepbar keeps a local SQLite baseline for every synced file: the hash and revision it had the moment it was last written to disk. On each sync it compares three states — the baseline, the current local file, and the current remote file:

- **Only the remote changed** → the new version is downloaded and replaces the local copy.
- **Only the local file changed** (you annotated a slide PDF, or edited it on iPad/Mac) → your copy is left untouched, and the baseline is quietly caught up so Beepbar knows your edit is now the source of truth.
- **Both changed** → Beepbar can't safely pick a winner, so it isolates the incoming version and surfaces an explicit conflict: keep your local copy, or switch to the remote one.

Downloads are staged atomically before being installed, so an interrupted sync (crash, closed lid, lost connection) never leaves a half-written file behind.

## Why Beepbar

I wanted something built specifically for macOS: a small app that stays in the menu bar, does not keep a window open, and avoids aggressive background polling. It should be responsive when I need it and quiet when I leave it running throughout the day.

In a preliminary local measurement of the Release build, with automatic sync disabled, Beepbar stayed around 14–15 MiB of memory for 30 minutes with effectively idle CPU use. This is a development reference, not a universal guarantee — but it's the kind of footprint you'd expect from a native Swift app with no bundled runtime, as opposed to Electron/TypeScript-based alternatives, which ship a full Chromium and Node.js runtime and typically carry a much heavier baseline memory and CPU cost.

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

## Contributing

Found a bug or have a feature request? [Open an issue](https://github.com/T-vaccari/Beepbar/issues). Pull requests are welcome too.

## License

[MIT](LICENSE)

Beepbar is not affiliated with Politecnico di Milano or WeBeep.
