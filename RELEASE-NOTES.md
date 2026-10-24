# AM Track 2.9.0 Beta 1

First downloadable beta for Apple Silicon Macs running macOS 13 or later.

1. **First launch:** Choose when Music access and local recording begin, with setup instructions and a link to Automation settings if permission is denied.
2. **Your listening history:** Start with your own empty archive, import library metadata for recommendations, and record future listening while AM Track is running.
3. **Remembered recording:** Reopening the app restores your recording choice; closing the window keeps it running in the menu bar.
4. **Continuous playback:** Keep one recommended song queued next, prepare later choices locally, and continue from saved albums without waiting for a new ranking pass.

Download `AM-Track-2.9.0-beta.1-macOS-arm64.zip`, unzip it, and move `AM Track.app` to Applications. The matching `.sha256` file contains its SHA-256 checksum. GitHub's automatically generated source-code archives require building the app yourself.

This beta is ad hoc signed and is **not notarized by Apple**. If macOS blocks opening it, follow the included installation guide and use **System Settings > Privacy & Security > Open Anyway** for AM Track if you trust the download. See [Apple's instructions](https://support.apple.com/102445).

All listening data and preferences stay on the user's Mac. The download contains no listening database or library export. Music itself may contact Apple for playback.

Queue additions use a private macOS interface and require verified catalog IDs. Compatibility varies by macOS version and track. This beta supports Apple Silicon only, and recording observes playback on the Mac while the app is running and the computer is awake.
