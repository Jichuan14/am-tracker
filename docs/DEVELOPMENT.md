# Development

[Back to the introduction](../README.md) · [中文介绍](../README.zh-CN.md)

## Build and run

Requires macOS 13 or later and Xcode Command Line Tools. From the repository folder:

```sh
./app-source/build.sh
open "app-source/.build/AM Track.app"
```

The build script compiles and locally signs the app, then runs included checks with test fixtures and mocked Music commands. Output goes in `app-source/.build/`.

Use `./app-source/build.sh Release` for an optimized build in `app-source/.build/Release/`. Add `--skip-tests` to compile and sign without running checks; tests run by default.

Editing source does not change a running app. Quit the installed app, replace its bundle with the new build, and relaunch. Preserve its data folder. macOS may ask to renew permissions after a rebuild.

## Package a beta

On an Apple Silicon Mac with Xcode Command Line Tools:

```sh
./scripts/package-release.sh
```

This builds and tests the optimized Release app, reconstructs a clean bundle from required files, and creates the app ZIP and SHA-256 checksum under `dist/`. Add `--skip-tests` only when intentionally packaging without tests. Only the app and installation instructions go into the ZIP. Use the matching [release notes](../RELEASE-NOTES.md) when publishing a beta. Packaging does not submit anything to Apple.

## Source layout

| Path | Contents |
| --- | --- |
| `app-source/main.swift` | Menu commands, recording model, and startup |
| `app-source/Interface.swift`, `DesignPreview.swift` | Native window views, menu heading, and isolated design renders |
| `app-source/MonthlyRankings.swift`, `MonthlyRecapWindow.swift`, `MonthlyRankingsTests.swift` | Monthly aggregation, dedicated local WebKit recap window, and isolated date/ranking/export checks |
| `app-source/HistoryStore.swift`, `UnifiedHistory.swift` | History storage, imports, and reconciliation |
| `app-source/Recommendations.swift`, `RecommendationRotation.swift`, `AlbumTaste.swift` | Recommendation ranking, persistent batch rotation, and album preferences |
| `app-source/MusicPlayback.swift`, `MusicQueue.swift`, `AutomaticPlayback.swift`, `BackgroundQueue.m` | Playback and queue integration |
| `app-source/QueueLatency.swift` | Bounded local queue timing diagnostics |
| `app-source/Resources/` | Scripts for reading and controlling Music |
| `app-source/*Tests.*` | History, recommendation, and playback checks |
| `app-source/build.sh`, `Info.plist` | Build script and app configuration |
| `docs/images/` | App screenshots used by both README versions |

## Keep runtime data out of the repository

Runtime files include `history.sqlite3`, `history.csv`, `status.json`, `database-health.json`, backups, and any selected `History.dat`. They contain private listening information and should stay local. Use **Open data folder** in the app to locate them.

This repository contains source and test fixtures, which may use real song names or public catalog IDs. Its `.gitignore` allows reviewed project files by name; databases, exports, reports, backups, app bundles, build caches, and unlisted files are excluded. Add an explicit allowlist entry when introducing a source file or documentation asset. Avoid force-adding runtime files.

## Interface and design previews

The window views and shared menu heading are in `app-source/Interface.swift`.
The native dropdown's command wiring is in `AppDelegate.updateMenu()` in
`main.swift`. See [DESIGN.md](../DESIGN.md) for the visual rules.

After building, generate native light/dark renders at normal size, minimum
width, minimum height, and both minimum dimensions:

```sh
"app-source/.build/AM Track.app/Contents/MacOS/AMTrack" \
  --design-preview "$PWD/app-source/.build/design-previews"
```

Add `--keep-open` to inspect the fixture window. In this preview, Command-D
opens the same native dropdown used by the status item. The preview creates
an isolated temporary archive with synthetic display data, starts no recorder,
and performs no automatic Music queries. Close it with Command-Q. The
production app uses the real model; fixture content is only used by the
explicit preview command. Generated renders stay in the ignored build folder.
Reviewed example renders and verification notes are in
[Design verification](DESIGN-VERIFICATION.md).
Use `--dark` with `--keep-open` to inspect the dropdown in Dark Aqua without
changing system appearance.

For the dedicated visual recap window, run:

```sh
"app-source/.build/AM Track.app/Contents/MacOS/AMTrack" \
  --design-preview "$PWD/app-source/.build/recap-previews" --recap --keep-open
```

This renders normal, minimum-width, minimum-height and minimum-combination
recap windows, plus songs, albums/activity, live-update and empty states. It
asserts that live data updates preserve focus and scroll and that untrusted
music metadata stays inert text. Preview data is synthetic and isolated.

The recap bundles buildless HTML/CSS/JS from `Resources/Recap/` in both Debug
and release packages. `MonthlyRecapWindow.swift` owns the AppKit window,
ephemeral WKWebView, native CSV export, and strict local-document bridge. No
HTTP server or remote assets are involved. The open page checks the published
monthly model every five seconds; recording continues through the existing
recorder. Month/metric selections and list expansion remain stable on updates.

Monthly charts and CSV keys use Gregorian months in the local time zone. The
recap rebases its selected civil month when the system time zone changes.
CSV export captures the chart’s calendar and metric before opening the save
sheet so a later time-zone change cannot relabel the saved month.
