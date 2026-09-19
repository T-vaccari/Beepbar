# Changelog

## Unreleased

### Fixed

- Signing in no longer has to be repeated because macOS keeps asking to authorize access to the Keychain. The WeBeep token is now kept in a file that only your own user account can read, inside Beepbar's Application Support folder, instead of in the Keychain. A token stored by an earlier version is moved over automatically the first time you open this one, and the old Keychain entry is removed.
- Synchronization no longer re-reads and re-hashes every file it has already downloaded. Each run used to read the full contents of every tracked file from disk just to check that it was still there, so a large library meant reading gigabytes on every manual and scheduled sync. Beepbar now only checks that the files exist, which makes a run over an unchanged folder far faster and much lighter on the disk.
- Files you have edited locally are no longer downloaded again on every synchronization. When the material on WeBeep changed only its revision and not its contents, Beepbar discarded the download but never recorded that it had caught up, so the same file was fetched again on every following run, forever.
- A tracked file that has been replaced by a folder no longer aborts the whole synchronization. Previously a single such entry made every run fail, with no way to recover other than choosing a different sync folder.
- Deleting a local file no longer lets an unrelated new material take over its name. The name stays reserved for the material it belongs to, and a genuinely new file is given a numbered suffix instead of making the run fail with a name collision.
- Database read errors are now reported instead of being mistaken for an empty result. A busy, locked or damaged database could return a partial view that Beepbar treated as complete: with no known baselines, every file you had annotated looked like a conflict and whole courses were downloaded again into " (1)" copies. Reads now fail loudly, and a database briefly locked by another operation is waited for rather than treated as broken.
- Choosing "Usa versione remota" for a file you had edited again in the meantime no longer leaves a stale second conflict behind. Exactly one conflict remains open for that file, reflecting the current contents on disk.
- Local recovery no longer stops at the first entry it cannot repair. A single damaged item used to abort recovery completely, and because recovery gates every other operation this blocked all synchronization, conflict resolution and folder renaming. The remaining items are now recovered normally and only the damaged one stays pending.
- Naming a course folder `.BEEPBAR`, or any other capitalisation of Beepbar's own hidden folder, is now refused instead of accepted. Because macOS folder names are not case-sensitive, such a folder was the same one Beepbar uses internally for downloads in progress and for conflict copies, so course materials were written into it and its contents could be overwritten or hidden from Finder.
- Renaming a course folder to a name already taken by another folder now says so, and leaves the course renameable. The rename failed with a generic message and, worse, left the course stuck: every later attempt to rename it failed too, and the next launch reported a local recovery it could never complete.
- When recovery does remain blocked, the menu bar now offers to retry it, and the message explains what to do. The only way out used to be choosing a different sync folder, which nothing on screen mentioned. Starting a synchronization while recovery is blocked is now refused explicitly instead of silently doing nothing.

### Performance

- The course list stays responsive with many courses. Showing a single row used to recompute the default folder name of every course, compiling regular expressions from scratch each time, which meant tens of thousands of recompilations per redraw with a large course list. Those names are now computed once and the regular expressions are compiled once for the lifetime of the app.

### Added and changed

- Keep synchronization controls visible while scrolling long course lists.
- Show how many materials were added or updated after every completed synchronization.
- Add a per-course breakdown ("Dettaglio") of what changed in the last sync, with newly-selected courses grouped to the top after syncing.
- Put the DMG first in the GitHub release assets and release notes.
- Keep the Sparkle update window compact and link directly to the changelog instead of embedding the GitHub release page.
- Build CI releases with the same Xcode 27 toolchain used for local Release builds.
- Show the changes included in each GitHub release from Beepbar's update flow.

## 2.0 beta

- Native Apple Silicon menu bar app with manual and scheduled WeBeep sync.
- Three-way synchronization that preserves local edits and exposes conflicts explicitly.
- Course selection and folder renaming, cancellable downloads, progress, and SQLite recovery.
- Keychain-backed authentication and opt-in updates through Sparkle.
