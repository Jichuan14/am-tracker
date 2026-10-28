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
            let month = MonthlySnapshot.monthStart(Date())
            var monthlyListens: [MonthlyListen] = []
            for (i, t) in tracks.enumerated() {
                for previous in [false, true] {
                    let start = MonthlySnapshot.calendar.date(byAdding: .month, value: previous ? -1 : 0, to: month)!
                    let count = previous ? [12, 17, 8, 0, 5, 3][i] : [23, 19, 14, 11, 7, 4][i]
                    let availableDays = previous ? MonthlySnapshot.calendar.range(of: .day, in: .month, for: start)!.count : MonthlySnapshot.calendar.component(.day, from: Date())
                    for n in 0..<count {
                        let day = MonthlySnapshot.calendar.date(byAdding: .day, value: (n * 7 + i * 3) % availableDays, to: start)!
                        monthlyListens.append(MonthlyListen(id: "monthly-\(previous)-\(i)-\(n)", trackID: "preview-\(i)",
                            title: t.0, artist: t.1, album: t.2, albumArtist: t.1,
                            observedAt: day.addingTimeInterval(Double(3600 + n * 90 + i * 220)), seconds: Double(137 + i * 23 + n * 3)))
                    }
                }
            }
            monthlyListens.append(MonthlyListen(id: "monthly-undated", trackID: "preview-undated", title: "Undated import", artist: "", album: "", albumArtist: "", observedAt: nil, seconds: 0))
            model.monthly = MonthlySnapshot(listens: monthlyListens)
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
            model.openMonthlyRecap = { [weak self] in self?.controller.showMonthlyRecap() }
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
            if CommandLine.arguments.contains("--recap") || CommandLine.arguments.contains("--monthly") {
                try renderRecap(model)
            } else { try renderAll(model) }
            if keepOpen {
                // Feedback expiry can start a ranking pass during the renders.
                model.suggestionRequest += 1
                model.suggestions = previewSongs
                model.nextRecommendations = .distantFuture
                show(model, tab: 4, size: NSSize(width: 1100, height: 680), dark: dark)
                if CommandLine.arguments.contains("--recap") || CommandLine.arguments.contains("--monthly") {
                    controller.showMonthlyRecap()
                } else { controller.showHistory() }
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
    private func recapScript(_ script: String) throws -> Any? {
        var finished = false
        var value: Any?
        var failure: Error?
        controller.monthlyRecap!.webView.evaluateJavaScript(script) { result, error in
            value = result; failure = error; finished = true
        }
        let deadline = Date().addingTimeInterval(8)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if let failure { throw failure }
        guard finished else { throw AppError(message: "Recap script timed out.") }
        return value
    }
    private func settleRecap() throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if controller.monthlyRecap!.ready,
               (try? recapScript("document.getElementById('status').textContent.includes('Connecting')")) as? Bool == false { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AppError(message: "Recap did not receive its local listening data.")
    }
    private func saveRecap(_ name: String) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        var image: NSImage?
        var finished = false
        var failure: Error?
        controller.monthlyRecap!.webView.takeSnapshot(with: nil) { result, error in
            image = result; failure = error; finished = true
        }
        let deadline = Date().addingTimeInterval(8)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if let failure { throw failure }
        guard let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw AppError(message: "Could not capture the recap page.")
        }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        print("Rendered \(name)")
    }
    private func renderRecap(_ model: Model) throws {
        let original = model.monthly
        controller.showMonthlyRecap()
        let recap = controller.monthlyRecap!
        try settleRecap()
        for (name, size) in [("normal", NSSize(width: 1180, height: 820)), ("minimum-width", NSSize(width: 760, height: 820)), ("minimum-height", NSSize(width: 1180, height: 572)), ("minimum", NSSize(width: 760, height: 572))] {
            recap.window.setContentSize(size)
            recap.window.center()
            _ = try recapScript("window.scrollTo(0,0)")
            try saveRecap("recap-" + name)
            guard (try recapScript("document.documentElement.scrollWidth <= window.innerWidth")) as? Bool == true else {
                throw AppError(message: "Recap overflows at " + name)
            }
        }
        recap.window.setContentSize(NSSize(width: 1180, height: 820))
        _ = try recapScript("window.scrollTo(0,500);document.getElementById('metric').focus();window.scrollY")
        let before = try recapScript("window.scrollY") as? Double
        let count = original.report(month: recap.month, category: .songs, metric: .entries).entryCount
        let song = original.listens.first!
        model.monthly.listens.append(MonthlyListen(id: "live-update-test", trackID: song.trackID, title: song.title, artist: song.artist,
            album: song.album, albumArtist: song.albumArtist, observedAt: recap.month.addingTimeInterval(3600), seconds: 61))
        recap.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard (try recapScript("Number(document.getElementById('entries').textContent.replaceAll(',',''))")) as? Int == count + 1,
              (try recapScript("window.scrollY")) as? Double == before,
              (try recapScript("document.activeElement.id")) as? String == "metric" else {
            throw AppError(message: "Live recap update changed focus/scroll or missed the new entry.")
        }
        guard (try recapScript("[...document.querySelectorAll('.rank-bar')].every(bar => Number.parseFloat(bar.style.width) >= 0 && Number.parseFloat(bar.style.width) <= 100) && Number.parseFloat(document.querySelector('#song-list .rank-bar').style.width) === 100")) as? Bool == true,
              (try recapScript("document.querySelectorAll('#day-chart .listening-line').length === 1 && document.querySelectorAll('#day-chart .grid-line').length === 4")) as? Bool == true else {
            throw AppError(message: "Recap graphs must have proportional rank bars and a labeled daily scale.")
        }
        _ = try recapScript("document.querySelector('#day-chart .data-point').focus();document.querySelector('#day-chart .data-point').dispatchEvent(new Event('focus'))")
        guard (try recapScript("document.getElementById('chart-readout').textContent.includes('min')")) as? Bool == true else {
            throw AppError(message: "Daily graph values must be inspectable with keyboard focus.")
        }
        try saveRecap("recap-live-update")
        _ = try recapScript("document.getElementById('metric').value='time';document.getElementById('metric').dispatchEvent(new Event('change'))")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard recap.metric == .time else { throw AppError(message: "Recap metric control did not reach the model.") }
        _ = try recapScript("document.getElementById('previous').click()")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard recap.month < MonthlySnapshot.monthStart(Date()),
              (try recapScript("document.getElementById('status').textContent")) as? String == "Archive" else {
            throw AppError(message: "Recap month navigation did not load archived listening.")
        }
        _ = try recapScript("document.getElementById('next').click()")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard recap.month == MonthlySnapshot.monthStart(Date()) else { throw AppError(message: "Recap next month did not return to the current month.") }
        _ = try recapScript("document.getElementById('more-songs').click();document.querySelector('details').open=true")
        recap.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard (try recapScript("document.getElementById('song-list').children.length")) as? Int == 6,
              (try recapScript("document.querySelector('details').open")) as? Bool == true else {
            throw AppError(message: "Live updates must preserve expanded songs and methodology details.")
        }
        _ = try recapScript("document.getElementById('more-songs').click();document.querySelector('details').open=false")
        recap.metric = .entries
        // Metadata must remain inert text inside the local WebKit surface.
        model.monthly = MonthlySnapshot(listens: [MonthlyListen(id: "escape", trackID: "escape", title: "<img src=x onerror=alert(1)>",
            artist: "</script> & Artist", album: "Album", albumArtist: "Artist", observedAt: recap.month, seconds: 65)])
        recap.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard (try recapScript("document.querySelectorAll('img,script:not([src])').length")) as? Int == 0,
              (try recapScript("document.getElementById('song-list').textContent.includes('<img src=x')")) as? Bool == true else {
            throw AppError(message: "Recap metadata must render as inert text.")
        }
        model.monthly = MonthlySnapshot(listens: [MonthlyListen(id: "long", trackID: "long", title: String(repeating: "A very long song title with 中文名字 ", count: 5),
            artist: String(repeating: "An artist with a long name ", count: 4), album: String(repeating: "Album title ", count: 6), albumArtist: "Album artist", observedAt: recap.month, seconds: 3_000_000)])
        recap.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        recap.window.setContentSize(NSSize(width: 760, height: 572))
        _ = try recapScript("window.scrollTo(0,0)")
        try saveRecap("recap-long-content")
        guard (try recapScript("document.documentElement.scrollWidth <= window.innerWidth")) as? Bool == true else {
            throw AppError(message: "Long recap names or large totals overflow the minimum window.")
        }
        model.monthly = MonthlySnapshot(); recap.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        recap.window.setContentSize(NSSize(width: 760, height: 572))
        _ = try recapScript("window.scrollTo(0,0)")
        try saveRecap("recap-empty")
        model.monthly = original; recap.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        recap.window.setContentSize(NSSize(width: 1180, height: 820))
        _ = try recapScript("window.scrollTo(0, document.getElementById('songs').offsetTop-25)")
        try saveRecap("recap-songs")
        _ = try recapScript("window.scrollTo(0, document.getElementById('albums').offsetTop-25)")
        try saveRecap("recap-albums-activity")
        _ = try recapScript("window.scrollTo(0,0)")
        print("PASS: dedicated recap window, responsive sizes, long content, live updates, stable focus/scroll/expansions, metric/month controls, inert metadata and empty state. No Music or network calls.")
        if !keepOpen { recap.window.close() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: folder)
    }
}
