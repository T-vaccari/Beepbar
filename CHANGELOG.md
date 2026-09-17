# Changelog

## Unreleased

- Keep synchronization controls visible while scrolling long course lists.
- Show how many materials were added or updated after every completed synchronization.
- Add a per-course breakdown ("Dettaglio") of what changed in the last sync, with newly-selected courses grouped to the top after syncing.
- Put the DMG first in the GitHub release assets and release notes.
- Keep the Sparkle update window compact and link directly to the changelog instead of embedding the GitHub release page.
- Build CI releases with the same Xcode 27 toolchain used for local Release builds.
- Show the changes included in each GitHub release from Beepbar's update flow.
- Stop re-reading every synced file on each sync; unchanged files are now checked without hashing, a synced path replaced by a folder no longer aborts the run, and a deleted file's name stays reserved for its own material.
- Stop re-downloading locally edited files on every sync once the remote copy is unchanged.
- Keep the course list responsive with many courses by caching default folder names.

## 2.0 beta

- Native Apple Silicon menu bar app with manual and scheduled WeBeep sync.
- Three-way synchronization that preserves local edits and exposes conflicts explicitly.
- Course selection and folder renaming, cancellable downloads, progress, and SQLite recovery.
- Keychain-backed authentication and opt-in updates through Sparkle.
