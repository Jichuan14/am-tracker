# Development

[Back to the introduction](../README.md) · [中文介绍](../README.zh-CN.md)

## Build and run

Requires macOS 13 or later and Xcode Command Line Tools. From the repository folder:

```sh
./app-source/build.sh
open "app-source/.build/AM Track.app"
```

The build script compiles and locally signs the app, then runs included checks with test fixtures and mocked Music commands. Output goes in `app-source/.build/`.

Editing source does not change a running app. Quit the installed app, replace its bundle with the new build, and relaunch. Preserve its data folder. macOS may ask to renew permissions after a rebuild.

## Package a beta

On an Apple Silicon Mac with Xcode Command Line Tools:

```sh
./scripts/package-release.sh
```

This builds and tests the app, reconstructs a clean bundle from required files, and creates the app ZIP and SHA-256 checksum under `dist/`. Only the app and installation instructions go into the ZIP. Use the matching [release notes](../RELEASE-NOTES.md) when publishing a beta. Packaging does not submit anything to Apple.

## Source layout

| Path | Contents |
| --- | --- |
| `app-source/main.swift` | App interface, menu bar, recording, and startup |
| `app-source/HistoryStore.swift`, `UnifiedHistory.swift` | History storage, imports, and reconciliation |
| `app-source/Recommendations.swift`, `AlbumTaste.swift` | Recommendation ranking and album preferences |
| `app-source/MusicPlayback.swift`, `MusicQueue.swift`, `AutomaticPlayback.swift`, `BackgroundQueue.m` | Playback and queue integration |
| `app-source/QueueLatency.swift` | Bounded local queue timing diagnostics |
| `app-source/Resources/` | Scripts for reading and controlling Music |
| `app-source/*Tests.*` | History, recommendation, and playback checks |
| `app-source/build.sh`, `Info.plist` | Build script and app configuration |
| `docs/images/` | App screenshots used by both README versions |

## Keep runtime data out of the repository

Runtime files include `history.sqlite3`, `history.csv`, `status.json`, `database-health.json`, backups, and any selected `History.dat`. They contain private listening information and should stay local. Use **Open data folder** in the app to locate them.

This repository contains source and test fixtures, which may use real song names or public catalog IDs. Its `.gitignore` allows reviewed project files by name; databases, exports, reports, backups, app bundles, build caches, and unlisted files are excluded. Add an explicit allowlist entry when introducing a source file or documentation asset. Avoid force-adding runtime files.
