# AM Track

A native macOS menu bar app for tracking listening in Music and finding songs to revisit from your library. Built with Swift, SwiftUI, SQLite, and JavaScript for Automation.

## Features

- Record the current song and playback position while recording is on.
- Search listening history and export it to CSV.
- Optionally import Music's `History.dat` and reconcile it with recorded observations.
- Get local song and album recommendations, with Like, Not now, and Less like this feedback.
- Play a selected song or your saved album tracks in order, and queue follow-up recommendations.

Recording starts off. Closing the window keeps the menu bar app running; quitting stops it. Album preferences start in automatic mode and can be changed in **Album preferences…**.

## Build and run

Requires macOS 13 or later and Xcode Command Line Tools. Playback and library access use the macOS Music app; Apple Music catalog availability depends on your account and library.

From the repository folder:

```sh
./app-source/build.sh
open "app-source/.build/AM Track.app"
```

The build script compiles and locally signs the app, then runs the included checks with synthetic data and mocked Music commands. Build output goes in `app-source/.build/`.

Allow AM Track to control Music when macOS requests Automation permission. Use **Start recording** in the menu bar to begin tracking. **Check History.dat** is optional and runs only when requested.

Queue additions use a private macOS playback interface. Compatibility may change with macOS updates, and tracks without a verified catalog ID cannot use this queue backend.

## Data and privacy

Listening history, library metadata, and recommendation feedback are stored locally. A new installation defaults to `~/Library/Application Support/AM Track/`. If an existing `history.sqlite3` is beside the app, that folder is used instead. **Open data folder** shows the active location.

Runtime files include `history.sqlite3`, `history.csv`, `status.json`, `database-health.json`, backups, and any selected `History.dat`. These contain private listening information and should stay on your Mac. Music itself may contact Apple's services for playback.

This repository contains source code and fictional test fixtures. Its `.gitignore` allows only the reviewed project files by name, so databases, exports, reports, backups, app bundles, build caches, and other unlisted files are excluded. Add an explicit allowlist entry when introducing a new source file. Avoid force-adding runtime files.

## Source layout

| Path | Contents |
| --- | --- |
| `app-source/main.swift` | App interface, menu bar, recording, and startup |
| `app-source/HistoryStore.swift`, `UnifiedHistory.swift` | History storage, imports, and reconciliation |
| `app-source/Recommendations.swift`, `AlbumTaste.swift` | Recommendation ranking and album preferences |
| `app-source/MusicPlayback.swift`, `MusicQueue.swift`, `BackgroundQueue.m` | Playback and queue integration |
| `app-source/Resources/` | Scripts for reading and controlling Music |
| `app-source/*Tests.*` | Synthetic history, recommendation, and playback checks |
| `app-source/build.sh`, `Info.plist` | Build script and app configuration |

