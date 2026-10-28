import AppKit
import WebKit
import UniformTypeIdentifiers

extension MonthlySnapshot {
    func recapPayload(month: Date, metric: MonthlyMetric, recording: Bool, now: Date = Date(),
                      calendar: Calendar = .current) -> [String: Any] {
        let start = Self.monthStart(month, calendar: calendar)
        let current = Self.monthStart(now, calendar: calendar)
        let report = self.report(month: start, category: .songs, metric: metric, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month], from: start)
        func monthKey(_ date: Date) -> String {
            let p = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", p.year!, p.month!)
        }
        func ranks(_ category: MonthlyCategory) -> [[String: Any]] {
            self.report(month: start, category: category, metric: metric, calendar: calendar).rows.map { row in
                ["id": row.id, "title": row.title, "subtitle": row.subtitle, "rank": row.rank,
                 "entries": row.entries, "seconds": row.seconds, "duration": monthlyDuration(row.seconds),
                 "movement": row.movement, "movementHelp": row.movementHelp,
                 "direction": row.previousRank.map { $0 > row.rank ? "up" : $0 < row.rank ? "down" : "same" } ?? "same"]
            }
        }
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        var daily: [Int: (entries: Int, seconds: Double)] = [:]
        for listen in listens {
            guard let date = listen.observedAt, date >= start, date < end else { continue }
            let day = calendar.component(.day, from: date)
            let old = daily[day] ?? (0, 0)
            daily[day] = (old.entries + 1, old.seconds + listen.seconds)
        }
        let days = calendar.range(of: .day, in: .month, for: start)!.map { day -> [String: Any] in
            ["day": day, "entries": daily[day]?.entries ?? 0, "seconds": daily[day]?.seconds ?? 0,
             "future": start == current && day > calendar.component(.day, from: now)]
        }
        let choices = Array(Set(listens.compactMap { $0.observedAt.map { Self.monthStart($0, calendar: calendar) } } + [current, start]))
            .filter { $0 <= current }.sorted(by: >).map { date in
                ["key": monthKey(date), "label": date.formatted(.dateTime.month(.wide).year())]
            }
        return ["month": monthKey(start), "monthName": start.formatted(.dateTime.month(.wide)),
                "year": parts.year!, "monthNumber": parts.month!, "months": choices,
                "current": start == current, "recording": recording, "metric": metric == .entries ? "entries" : "time",
                "minutes": Int(report.seconds / 60), "duration": monthlyDuration(report.seconds),
                "entries": report.entryCount, "songCount": report.songCount, "artistCount": report.artistCount,
                "activeDays": daily.count, "undated": report.undatedCount, "days": days,
                "songs": ranks(.songs), "artists": ranks(.artists), "albums": ranks(.albums),
                "updated": now.formatted(date: .omitted, time: .standard),
                "timeZone": calendar.timeZone.identifier]
    }
}

// All assets and listening data stay in-process. No web server, remote scripts,
// catalog lookups, analytics, or network permission is needed for the recap.
@MainActor final class MonthlyRecapWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let model: Model
    let window: NSWindow
    let webView: WKWebView
    var month = MonthlySnapshot.monthStart(Date())
    var metric: MonthlyMetric = .entries
    private(set) var ready = false
    private var timer: Timer?
    private var lastPayload: Data?
    private var delivering = false
    private var pendingUpdate = false

    init(model: Model) {
        self.model = model
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Your month · AM Track"
        window.minSize = NSSize(width: 760, height: 600)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1)
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
        configuration.userContentController.add(self, name: "recap")
        if let root = Bundle.main.resourceURL?.appendingPathComponent("Recap", isDirectory: true) {
            webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        }
        window.center()
    }
    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        if timer == nil {
            // The recorder publishes new observations every five seconds. This
            // also catches date rollover and status changes while this page is open.
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
    func refresh() {
        guard ready else { return }
        if delivering { pendingUpdate = true; return }
        let payload = model.monthly.recapPayload(month: month, metric: metric, recording: model.recording)
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoded != lastPayload else { return }
        delivering = true
        webView.callAsyncJavaScript("window.Recap.update(payload)", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.delivering = false
            if case .success = result { self.lastPayload = encoded }
            if self.pendingUpdate { self.pendingUpdate = false; self.refresh() }
        }
    }
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the bundled top-level document can invoke native commands. Copy
        // simple values before handing the action to the archive's main owner.
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let value = body["value"] as? String ?? ""
        let category = body["category"] as? String ?? ""
        Task { @MainActor [weak self] in self?.handleCommand(action, value: value, category: category) }
    }
    private func handleCommand(_ action: String, value: String, category: String) {
        switch action {
        case "ready": ready = true; refresh()
        case "month":
            if !value.isEmpty {
                let parts = value.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2, (1...9999).contains(parts[0]), (1...12).contains(parts[1]),
                   let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
                   date <= MonthlySnapshot.monthStart(Date()) { month = date; refresh() }
            }
        case "previous", "next":
            if let date = Calendar.current.date(byAdding: .month, value: action == "previous" ? -1 : 1, to: month),
               date <= MonthlySnapshot.monthStart(Date()) { month = date; refresh() }
        case "metric": metric = value == "time" ? .time : .entries; refresh()
        case "refresh": model.reload(); refresh()
        case "export":
            let selectedCategory = MonthlyCategory.allCases.first { $0.id.lowercased() == category } ?? .songs
            export(selectedCategory)
        default: break
        }
    }
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let root = Bundle.main.resourceURL?.appendingPathComponent("Recap", isDirectory: true).standardizedFileURL.path ?? ""
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true && url!.standardizedFileURL.path.hasPrefix(root + "/") ? .allow : .cancel)
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ready = false; self.lastPayload = nil; self.webView.reload()
        }
    }
    private func export(_ category: MonthlyCategory) {
        let report = model.monthly.report(month: month, category: category, metric: metric)
        guard !report.rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let parts = Calendar.current.dateComponents([.year, .month], from: month)
        panel.nameFieldStringValue = String(format: "monthly-%04d-%02d-%@.csv", parts.year!, parts.month!, category.rawValue.lowercased())
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try monthlyCSV(report, category: category, metric: self.metric).write(to: url, atomically: true, encoding: .utf8) }
            catch {
                let alert = NSAlert(); alert.messageText = "Could not export rankings"; alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: self.window)
            }
        }
    }
}
