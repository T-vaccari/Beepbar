# Beepbar

An unofficial native macOS app for syncing WeBeep course materials locally. It is deliberately vertical: Apple Silicon only, lightweight in the background, and built around one safety guarantee that other sync clients often miss — local work is never silently overwritten.

## Features

- discreet menu-bar app with clear sync status and contextual actions;
- browser-based WeBeep login, with the token stored in the macOS Keychain;
- manual or configurable automatic sync;
- controlled parallel downloads, byte-level progress, and real cancellation;
- selectable sync root and editable course-folder names;
- three-way sync backed by SQLite, atomic staging, and rename-on-commit;
- explicit conflict resolution: keep the local version or deliberately replace it with the remote one.

## Why Beepbar

I wanted a macOS-only client that could stay in the background without becoming another heavy app: responsive when opened, quiet when idle, and focused solely on WeBeep materials instead of cross-platform abstractions.

The core reason is safety. Imagine editing a PDF locally and then finding a newer remote copy: a conventional client may overwrite your edit because the two files differ. Beepbar detects that both versions changed, keeps them separate, and asks you which one to keep. Nothing is discarded until you make that choice.

In a preliminary local measurement of the Release build, with automatic sync disabled, Beepbar stayed around 14–15 MiB of memory for 30 minutes with effectively idle CPU use. This is a development reference, not a universal guarantee.

## Requirements

- macOS 14 or later
- Apple Silicon

## Installation

1. Download `Beepbar-unsigned.dmg` from the latest release and drag Beepbar into Applications.
2. On first launch, right-click Beepbar and choose **Open**. If macOS blocks it, go to **System Settings > Privacy & Security** and choose **Open Anyway**.
3. Open Beepbar from the menu bar, sign in to WeBeep in the browser, and choose the local sync folder.

The arm64 DMG is currently unsigned and not notarized, so the initial Gatekeeper step is expected. Advanced users can instead run this after moving the app into Applications:

```sh
xattr -dr com.apple.quarantine /Applications/Beepbar.app
```

## Sviluppo

```sh
swift test
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO
scripts/create-dmg.sh build/Release/Beepbar.app build/Beepbar-unsigned.dmg
```

CI runs the tests and builds an unsigned arm64 DMG.

Beepbar is not affiliated with Politecnico di Milano or WeBeep.
