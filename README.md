# AM Track

A native macOS menu bar app for tracking listening in Music and finding songs to revisit from your library. Built with Swift, SwiftUI, SQLite, and JavaScript for Automation.

## Features

- Record the current song and playback position while recording is on.
- Search listening history and export it to CSV.
- Optionally import Music's `History.dat` and reconcile it with recorded observations.
- Get local song and album recommendations, with Like, Not now, and Less like this feedback.
- Play a selected song or your saved album tracks in order, and queue follow-up recommendations.

On first launch, choose **Enable recording** to allow local collection, or **Not now** to leave Music access off. Your recording choice is remembered across launches. Closing the window keeps the menu bar app running; quitting stops it. Album preferences start in automatic mode and can be changed in **Album preferences…**.

## Download and install

Download the app ZIP from [GitHub Releases](https://github.com/Jichuan14/am-tracker/releases), unzip it, and move `AM Track.app` to Applications. The first beta supports **Apple Silicon Macs running macOS 13 or later**. You do not need Xcode or developer tools to use the downloaded app.

This beta is ad hoc signed and **not notarized by Apple**. If macOS blocks it, use **System Settings > Privacy & Security > Open Anyway** for AM Track if you trust the download. See the [installation guide](INSTALL.txt) and [Apple's instructions](https://support.apple.com/102445). The release also includes a SHA-256 checksum file.

Open Music, choose **Enable recording**, and allow AM Track to control Music when prompted. AM Track reads your own library metadata and records future listening on this Mac. Past play counts help recommendations without being converted into invented listening events. Recommendations may initially be empty if the library has no saved songs or listening evidence.

## Build and run

Requires macOS 13 or later and Xcode Command Line Tools. Playback and library access use the macOS Music app; Apple Music catalog availability depends on your account and library.

From the repository folder:

```sh
./app-source/build.sh
open "app-source/.build/AM Track.app"
```

The build script compiles and locally signs the app, then runs the included checks with test fixtures and mocked Music commands. Build output goes in `app-source/.build/`.

Allow AM Track to control Music when macOS requests Automation permission. Use **Start recording** in the menu bar to begin tracking. **Check History.dat** is optional and runs only when requested.

Queue additions use a private macOS playback interface. Compatibility may change with macOS updates, and tracks without a verified catalog ID cannot use this queue backend.

## Data and privacy

Listening history, library metadata, and recommendation feedback are stored locally. A new installation defaults to `~/Library/Application Support/AM Track/`. If an existing `history.sqlite3` is beside the app, that folder is used instead. **Open data folder** shows the active location.

Runtime files include `history.sqlite3`, `history.csv`, `status.json`, `database-health.json`, backups, and any selected `History.dat`. These contain private listening information and should stay on your Mac. Music itself may contact Apple's services for playback.

AM Track does not upload listening data or send analytics. Library metadata and playback controls can continue refreshing after recording stops, once Music access has been enabled. Recording requires the app to be running while the Mac is awake and does not collect listening from other devices. No login item is installed.

This repository contains source code and test fixtures, which may use real song names or public catalog IDs. Its `.gitignore` allows only reviewed project files by name, so databases, exports, reports, backups, app bundles, build caches, and other unlisted files are excluded. Add an explicit allowlist entry when introducing a new source file. Avoid force-adding runtime files.

## Package a beta

On an Apple Silicon Mac with Xcode Command Line Tools, run:

```sh
./scripts/package-release.sh
```

This builds and tests the app, reconstructs a clean bundle from required files, and creates the app ZIP and SHA-256 checksum under `dist/`. Only the app and installation instructions go into the ZIP. Upload those two assets to a GitHub pre-release tagged `v2.9.0-beta.1`, using [the release notes](RELEASE-NOTES.md). Packaging does not submit anything to Apple.

## Source layout

| Path | Contents |
| --- | --- |
| `app-source/main.swift` | App interface, menu bar, recording, and startup |
| `app-source/HistoryStore.swift`, `UnifiedHistory.swift` | History storage, imports, and reconciliation |
| `app-source/Recommendations.swift`, `AlbumTaste.swift` | Recommendation ranking and album preferences |
| `app-source/MusicPlayback.swift`, `MusicQueue.swift`, `AutomaticPlayback.swift`, `BackgroundQueue.m` | Playback and queue integration |
| `app-source/QueueLatency.swift` | Bounded local queue timing diagnostics |
| `app-source/Resources/` | Scripts for reading and controlling Music |
| `app-source/*Tests.*` | Synthetic history, recommendation, and playback checks |
| `app-source/build.sh`, `Info.plist` | Build script and app configuration |

