import AppKit
import SwiftUI

// Reproducible native renders use a temporary archive and synthetic view data.
// This path never starts the recorder, polls Music, or opens the user's archive.
@MainActor final class DesignPreview: NSObject, NSApplicationDelegate {
    let output: URL
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("am-track-design-" + UUID().uuidString)
    var controller: AppDelegate!
    var keepOpen: Bool
    let dark = CommandLine.arguments.contains("--dark")
    init(output: URL, keepOpen: Bool) { self.output = output; self.keepOpen = keepOpen }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let model = try Model(folder: folder)
            model.suggestionRequest += 1 // Discard the empty archive's asynchronous initial ranking.
            model.nextRecommendations = .distantFuture
            model.showSetup = false
            model.collectionEnabled = true
            model.recording = true
            model.lastCheck = "3:42 PM"
            model.menuSample = Sample(["running": true, "state": "playing", "title": "Garden Song", "artist": "Phoebe Bridgers", "album_artist": "Phoebe Bridgers", "album": "Punisher", "persistent_id": "AA00000000000001"])
            model.sample = model.menuSample
            try model.archive.feedbackForCurrentSong(model.menuSample!, "like")
            try model.archive.feedback("preview-0", "like")
            try model.archive.feedback("preview-2", "less")
            try model.refreshFeedback()
            let tracks: [(String, String, String, String, Bool)] = [
                ("I Know the End", "Phoebe Bridgers", "Punisher", "A longtime favorite, last played 42 days ago", false),
                ("惬意", "陳綺貞", "旅行的意義", "An album you return to, ready for another listen", true),
                ("This Must Be the Place (Naive Melody)", "Talking Heads", "Speaking in Tongues", "A familiar favorite outside your recent rotation", false),
                ("Everything In Its Right Place", "Radiohead", "Kid A", "From an album you often listen to in full", false),
                ("A Walk", "Tycho", "Dive", "A quieter corner of your saved library", false),
                ("Pink Moon", "Nick Drake", "Pink Moon", "An album worth hearing from the beginning", true)
            ]
            model.suggestions = tracks.enumerated().map { i, t in
                Recommendation(id: "preview-\(i)", title: t.0, artist: t.1, album: t.2, catalogID: "", reason: t.3, score: 1, bucket: "favorite", kind: t.4 ? .album : .song, albumID: t.4 ? "album-\(i)" : nil, trackIDs: t.4 ? ["a", "b", "c", "d", "e", "f", "g", "h"] : ["preview-\(i)"], playbackIssue: nil)
            }
            model.history = (0..<24).map { i in
                let t = tracks[i % tracks.count]
                return HistoryRow(id: "row-\(i)", trackID: "preview-\(i)", date: i == 0 ? "Oct 24, 3:38 PM" : "Date unknown", title: t.0, artist: t.1, album: t.2, amount: i == 0 ? "173 sec" : "Unknown", detail: i == 0 ? "Recording" : "Music history")
            }
            model.historyStatus = "Imported sequence; dates and completion are unknown."
            model.historyIsLive = true
            model.albumOptions = [AlbumCollection(id: "album-1", artist: "陳綺貞", title: "旅行的意義", tracks: []), AlbumCollection(id: "album-2", artist: "Nick Drake", title: "Pink Moon", tracks: [])]
            // All playback entry points fail locally in preview mode, before Music is queried.
            model.playbackReadOverride = { ["running": true, "state": "playing", "title": "Garden Song", "artist": "Phoebe Bridgers", "album_artist": "Phoebe Bridgers", "album": "Punisher", "persistent_id": "AA00000000000001"] }
            model.playbackStartOverride = { _ in throw AppError(message: "Playback is unavailable in design preview.") }
            model.catalogResolveOverride = { _ in throw AppError(message: "Queueing is unavailable in design preview.") }
            model.queueAppendOverride = { _ in throw AppError(message: "Queueing is unavailable in design preview.") }
            model.queryControl.cancel(); model.libraryDetailsControl.cancel(); model.menuSongControl.cancel()
            controller = AppDelegate()
            controller.model = model
            controller.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            controller.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            controller.window.title = "AM Track · Design preview"
            controller.window.minSize = NSSize(width: 888, height: 490)
            controller.window.isReleasedWhenClosed = false
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.createAppMenu()
            controller.updateMenu()
            let previewItem=NSMenuItem(title:"Preview dropdown",action:#selector(openDropdown),keyEquivalent:"d")
            previewItem.target=self
            NSApp.mainMenu?.items.first?.submenu?.insertItem(previewItem,at:0)
            show(model, tab: 4, size: NSSize(width: 1100, height: 680), dark: false)
            // Capture after AppKit finishes activating the app and native controls.
            perform(#selector(renderPreview), with: nil, afterDelay: 0.4)
        } catch {
            fputs("Design preview failed: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    @objc private func renderPreview() {
        let model = controller.model!
        let previewSongs = model.suggestions
        do {
            try renderAll(model)
            if keepOpen {
                // Feedback expiry can start a ranking pass during the renders.
                model.suggestionRequest += 1
                model.suggestions = previewSongs
                model.nextRecommendations = .distantFuture
                show(model, tab: 4, size: NSSize(width: 1100, height: 680), dark: dark)
                controller.showHistory()
            } else {
                NSStatusBar.system.removeStatusItem(controller.item)
                try? FileManager.default.removeItem(at: folder)
                NSApp.terminate(nil)
            }
        } catch {
            fputs("Design preview failed: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    @objc private func openDropdown() {
        controller.updateMenu()
        guard let menu = controller.item.menu, let view = controller.window.contentView else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.width - 355, y: view.bounds.height - 8), in: view)
    }

    private func show(_ model: Model, tab: Int, size: NSSize, dark: Bool) {
        model.selectedTab = tab
        let host = NSHostingView(rootView: AppContentView(model: model))
        host.sizingOptions = []
        controller.window.contentView = host
        controller.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.window.setContentSize(size)
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        NSApp.updateWindows()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        controller.window.displayIfNeeded()
    }
    private func save(_ name: String) throws {
        guard let view = controller.window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError(message: "Cannot render \(name)") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError(message: "Cannot encode \(name)") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        print("Rendered \(name): \(Int(view.bounds.width)) × \(Int(view.bounds.height))")
    }
    private func renderAll(_ model: Model) throws {
        let savedSongs = model.suggestions
        let savedSample = model.menuSample
        defer {
            model.suggestions = savedSongs; model.menuSample = savedSample; model.sample = savedSample
            model.recording = true; model.showSetup = false
        }
        for dark in [false, true] {
            for (suffix, size) in [("normal", NSSize(width: 1100, height: 680)), ("minimum-width", NSSize(width: 888, height: 680)), ("minimum-height", NSSize(width: 1100, height: 462)), ("minimum", NSSize(width: 888, height: 462))] {
                for tab in [0, 4] {
                    show(model, tab: tab, size: size, dark: dark)
                    try save("\(tab == 0 ? "history" : "for-you")-\(dark ? "dark" : "light")-\(suffix)")
                }
            }
        }
        // Saved likes stay invisible until a new click creates a short-lived receipt.
        show(model, tab: 4, size: NSSize(width: 888, height: 462), dark: false)
        try save("like-before")
        model.feedbackConfirmation = FeedbackConfirmation(title: "I Know the End", kind: "like", targetID: "preview-0")
        show(model, tab: 4, size: NSSize(width: 888, height: 462), dark: false)
        try save("like-confirmation")
        RunLoop.current.run(until: Date().addingTimeInterval(3.1))
        guard model.feedbackConfirmation == nil, model.songFeedback["preview-0"]?.liked == true else {
            throw AppError(message: "Like confirmation must expire without clearing saved preference.")
        }
        show(model, tab: 4, size: NSSize(width: 888, height: 462), dark: false)
        try save("like-after")
        model.feedbackConfirmation = FeedbackConfirmation(title: "This Must Be the Place (Naive Melody)", kind: "less")
        show(model, tab: 4, size: NSSize(width: 888, height: 462), dark: false)
        try save("feedback-confirmation")
        model.feedbackConfirmation = nil
        model.suggestions = []
        show(model, tab: 4, size: NSSize(width: 888, height: 462), dark: false)
        try save("for-you-empty")
        model.recording = false; model.menuSample = nil; model.sample = nil
        show(model, tab: 0, size: NSSize(width: 888, height: 462), dark: false)
        try save("recording-off")
        model.showSetup = true
        show(model, tab: 0, size: NSSize(width: 888, height: 462), dark: false)
        try save("setup-minimum")
        model.showSetup = false
    }
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: folder)
    }
}
