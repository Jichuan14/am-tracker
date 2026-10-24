# AM Track

**Keep a listening history. Rediscover your Music library.**

English | [简体中文](README.zh-CN.md)

AM Track is a native macOS menu bar app that records what you play in Music and helps you choose what to hear next. Browse your listening history, return to old favorites, play saved albums in order, and keep recommendations coming as you listen. Your history and preferences stay on your Mac.

[Download the beta](https://github.com/Jichuan14/am-tracker/releases) · [Installation guide](INSTALL.txt) · [Release notes](RELEASE-NOTES.md)

![For you recommendations with reasons, playback controls, and feedback buttons](docs/images/for-you.jpg)

## What you can do

### Revisit your listening history

Turn on recording to save songs and observed listening time as Music plays. Search by song or artist, see where each entry came from, and export your history to CSV.

You can also check Music's `History.dat` manually to fill recording gaps. AM Track reconciles matching sequences into one history, keeping unknown dates and listening durations marked as unknown. Library play counts help recommendations without becoming invented listening events.

![History showing recorded listening, imported Music entries, search, and CSV export](docs/images/history.jpg)

### Find something worth playing again

**For you** recommends songs and albums from your saved library. It combines listening history, library play counts, recent listening, and your feedback to bring back old favorites alongside less-played music. Each recommendation includes a short reason. Songs known to have played in the last 24 hours are excluded.

**Refresh** favors choices absent from the previous three batches within seven days. If fresh choices run out, the least recently shown items can return. The current batch survives restarts and background updates; playback and feedback replace ineligible items while keeping the remaining order.

| Control | What it does |
| --- | --- |
| **Play** | Starts the selected song in Music. |
| **Like** | Marks a song or album as an explicit preference. Playing it does not automatically Like it. |
| **Not now** | Hides the recommendation for 24 hours. |
| **Less like this** | Hides the item and reduces recommendations with similar metadata. |
| **Undo last feedback** | Reverses your latest rating or album listening preference change. |
| **Find in Music** | Opens a search in Music. |

You can also rate the current song from the menu bar or **For you**, and rate past songs by right-clicking them in **History**.

### Listen to albums your way

In **Album preferences…**, choose **Learn from listening**, **Prefer whole album**, or **Prefer individual songs** for each album. Automatic learning looks for repeated album listening, while individual song Likes remain separate.

When an album is recommended, **Play album** plays the songs you have saved from it in disc and track order. This covers your saved tracks, which may be only part of the release.

![Album preferences with a listening-style selector for each saved album](docs/images/album-preferences.jpg)

### Keep the next song ready

**Next for you** adds one recommended song to the end of Music's queue without interrupting the current track. Automatic queueing prepares future choices and adds a replacement as monitored playback advances. Playing a recommendation also enables it; album playback waits until the album's follow-up song before replenishing.

**Stop auto queue** stops future additions and leaves songs already queued in place. Queueing works in the background without bringing Music forward or requiring Accessibility access.

### Control it from the menu bar

See the current song, start or stop recording, give feedback, and play recommendations without opening the main window. Closing the window keeps AM Track running. Quitting stops it, and your recording choice is remembered when you reopen it.

## Get started

The downloadable beta supports **Apple Silicon Macs running macOS 13 or later** and uses the macOS Music app. No developer tools are needed for the download.

1. Download the app ZIP from [Releases](https://github.com/Jichuan14/am-tracker/releases), unzip it, and move **AM Track.app** to Applications.
2. Open AM Track and Music. Choose **Enable recording** and allow AM Track to control Music when prompted. **Not now** leaves Music access and recording off.
3. Play music to build your history, then open **For you** to explore recommendations. Save songs to your Music library first; an empty library or limited listening evidence can leave recommendations empty.

The beta is ad hoc signed and **not notarized by Apple**. If macOS blocks it and you trust the download, use **System Settings > Privacy & Security > Open Anyway**. See the [installation guide](INSTALL.txt) for details.

## Your data stays local

AM Track stores listening history, library metadata, and feedback locally and does not upload them or send analytics. Music itself may contact Apple's services for playback.

New installations use `~/Library/Application Support/AM Track/`. An existing database beside the app or a previously selected data folder may be used instead. **Open data folder** shows the active location; **Export history** creates `history.csv`. Quit AM Track before backing up its data folder.

After Music access is enabled, library metadata and playback controls can refresh with recording off. Recording observes this Mac while the app is running and the Mac is awake. It does not collect listening from other devices, and no login item is installed.

Queue additions require verified catalog IDs and use a private macOS playback interface. Some tracks, including local imports without those IDs, cannot be queued this way, and compatibility may change with macOS updates. Recommendations currently come from your saved library.

## Build from source

Built with Swift, SwiftUI, SQLite, and JavaScript for Automation. Requires macOS 13 or later and Xcode Command Line Tools.

```sh
./app-source/build.sh
open "app-source/.build/AM Track.app"
```

The script compiles and locally signs the app, then runs isolated checks. For source layout and beta packaging, see [Development](docs/DEVELOPMENT.md).
