import AppKit
import SwiftUI

// Shared native surfaces. Semantic colors follow the Mac's appearance and accent.
enum Interface {
    static let menuWidth: CGFloat = 340
    // Reserve native state, icon, keyboard-shortcut and edge columns.
    static let menuTextWidth: CGFloat = menuWidth - 110
    static let inset: CGFloat = 24
    static let radius: CGFloat = 10
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let content = Color(nsColor: .textBackgroundColor)
}

struct RecordingIndicator: View {
    let recording: Bool
    var body: some View {
        Label(recording ? "Recording on" : "Recording off", systemImage: recording ? "record.circle" : "pause.circle")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(recording ? Color.accentColor : .secondary)
    }
}

struct MediaMark: View {
    var album = false
    var size: CGFloat = 42
    var body: some View {
        Image(systemName: album ? "square.stack" : "music.note")
            .font(.system(size: size * 0.39, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: Interface.radius))
            .accessibilityHidden(true)
    }
}

struct NowPlayingSummary: View {
    let sample: Sample?
    var compact = false
    var body: some View {
        HStack(spacing: 12) {
            MediaMark(size: compact ? 38 : 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(sample?.title.isEmpty == false ? (sample?.state == "playing" ? "Now playing" : "In Music") : "Your music, remembered")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(sample?.title.isEmpty == false ? sample!.title : "Nothing playing")
                    .font(.system(size: compact ? 13 : 15, weight: .semibold)).lineLimit(1)
                    .help(sample?.title ?? "Nothing playing")
                Text(sample?.title.isEmpty == false ? [sample!.albumArtistLabel, sample!.album].filter { !$0.isEmpty }.joined(separator: " · ") : "Play something in Music to get started.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AppContentView: View {
    @ObservedObject var model: Model
    var body: some View {
        Group {
            if model.showSetup { SetupView(model: model) }
            else { HistoryView(model: model) }
        }.tint(.accentColor)
    }
}

struct SetupView: View {
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MediaMark(size: 52)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make room for rediscovery.").font(.system(size: 28, weight: .semibold))
                    Text("A listening history and a fresh way back to your Music library.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Divider()
                setupRow("music.note", title: "Connect your Music library", detail: "Use song details, play counts, and last-played dates to rediscover music you already own.")
                setupRow("waveform", title: "Record from now on", detail: "Check playback every 5 seconds while this Mac is awake. Existing play counts never become invented past listens.")
                setupRow("internaldrive", title: "Keep it on your Mac", detail: "History and preferences stay here. AM Track sends no analytics. Music may contact Apple for playback.")
                Text("Open Music, then enable recording. macOS will ask for permission to control Music. You can stop recording from the menu bar at any time.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.error.isEmpty { Label(model.error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Button("Not now") { model.showSetup = false }
                    Spacer()
                    Button("Enable recording") { model.finishSetup() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.controlSize(.large)
            }.padding(36).frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
        }.background(Interface.canvas)
    }
    func setupRow(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: Model
    @State private var search = ""
    @State private var showHistoryDetails = false
    var rows: [HistoryRow] {
        model.history.filter { search.isEmpty || [$0.title, $0.artist, $0.album].joined(separator: " ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Picker("Page", selection: $model.selectedTab) {
                        Text("History").tag(0)
                        Text("For you").tag(4)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Button { model.openMonthlyRecap?() } label: { Label("Monthly recap", systemImage: "chart.bar.xaxis") }
                        .help("Open your live monthly listening recap in its own window")
                    Spacer()
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(model.selectedTab == 4 ? "Search recommendations" : "Search history", text: $search)
                            .textFieldStyle(.plain).accessibilityLabel("Search songs, artists, or albums")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                        }
                    }.font(.system(size: 12)).padding(8).frame(width: 240)
                        .background(Interface.content, in: RoundedRectangle(cornerRadius: 7))
                }
                if !model.collectionEnabled {
                    HStack {
                        Label("Connect Music to start your listening history.", systemImage: "music.note")
                        Spacer()
                        Button("Set up Music access") { model.showSetup = true }
                    }.font(.system(size: 12))
                }
                if !model.error.isEmpty || !model.libraryDetailsError.isEmpty {
                    HStack(alignment: .top) {
                        Label(model.error.isEmpty ? model.libraryDetailsError : model.error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button("Automation settings") { model.openAutomationSettings() }
                    }.font(.system(size: 12))
                }
                if model.selectedTab == 4 {
                    SuggestionsView(model: model, search: search)
                } else {
                    historyContent
                }
            }.padding(Interface.inset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }.background(Interface.canvas)
    }
    private var header: some View {
        HStack(spacing: 24) {
            NowPlayingSummary(sample: model.menuSample ?? model.sample)
            if let current = model.menuSample, current.musicPersistentID != nil {
                SongFeedbackButtons(title: current.title, feedback: model.currentSongFeedback,
                    likeConfirmed: model.feedbackConfirmation?.isLike(for: "persistent:" + (current.musicPersistentID ?? "")) == true,
                    like: { model.rateCurrent(current, "like") },
                    dislike: { model.rateCurrent(current, model.currentSongFeedback.less ? "reset" : "less") })
            }
            Divider().frame(height: 36)
            VStack(alignment: .trailing, spacing: 6) {
                RecordingIndicator(recording: model.recording)
                Button(model.recording ? "Stop recording" : "Start recording") { model.recording ? model.stop() : model.start() }
                    .controlSize(.regular)
                    .accessibilityHint("Controls the history recorder. Does not change Music playback.")
            }.fixedSize()
        }.padding(.horizontal, Interface.inset).padding(.vertical, 18)
    }
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Listening history").font(.system(size: 23, weight: .semibold))
                    Text("Your plays, in one place.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { export() } label: { Label("Export history", systemImage: "square.and.arrow.up") }
            }
            DisclosureGroup(isExpanded: $showHistoryDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.historyStatus.isEmpty ? "History has not been checked yet." : model.historyStatus)
                    Text("Music’s checked sequence fills recording gaps. Dates are recording observations; undated entries keep Music’s order.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(model.databaseStatus).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.historyBusy ? "Checking…" : "Check History.dat") { model.checkHistory() }.disabled(model.historyBusy)
                        Button("Choose History.dat…") { model.chooseHistory() }
                    }
                    if !model.historyChecked.isEmpty { Text("Last checked \(model.historyChecked). Checks run only when requested.").foregroundStyle(.secondary) }
                }.padding(.top, 8).textSelection(.enabled)
            } label: {
                Label("History sources and checks", systemImage: "info.circle").foregroundStyle(.secondary)
            }.font(.system(size: 12))
            if !model.historyProblem.isEmpty {
                Label(model.historyProblem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            }
            Table(rows) {
                TableColumn("Observed", value: \.date).width(min: 115, ideal: 145, max: 180)
                TableColumn("Song") { row in
                    HStack(spacing: 7) {
                        Text(row.title).fontWeight(.medium).help(row.title)
                        FeedbackMark(feedback: model.songFeedback[row.trackID] ?? RecommendationFeedback())
                    }.contextMenu {
                        Button("Like") {
                            model.rate(row.trackID, "like")
                        }
                        Button("Not now") { model.rate(row.trackID, "later") }
                        Button(model.songFeedback[row.trackID]?.less == true ? "Remove dislike" : "Less like this") {
                            model.rate(row.trackID, model.songFeedback[row.trackID]?.less == true ? "reset" : "less")
                        }
                    }
                }.width(min: 150, ideal: 260)
                TableColumn("Album artist", value: \.artist).width(min: 95, ideal: 150)
                TableColumn("Listened") { row in Text(row.amount).monospacedDigit() }.width(min: 65, ideal: 75, max: 90)
                TableColumn("Source / note") { row in Text(row.detail).foregroundStyle(.secondary) }.width(min: 90, ideal: 160)
            }.clipShape(RoundedRectangle(cornerRadius: 8)).overlay {
                if rows.isEmpty {
                    EmptyLibraryView(searching: !search.isEmpty, title: "No history here yet", detail: "New listens appear while recording is on.")
                }
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if let confirmation = model.feedbackConfirmation {
                Label {
                    Text(confirmation.message).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: confirmation.symbol).foregroundStyle(confirmation.color)
                }.lineLimit(1).help(confirmation.message)
                    .accessibilityLabel(confirmation.message)
                Button("Undo") { model.undoFeedback() }.buttonStyle(.link)
                Button { model.feedbackConfirmation = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss feedback confirmation").accessibilityLabel("Dismiss feedback confirmation")
            } else if model.selectedTab == 4 {
                Text("\(model.suggestions.filter { search.isEmpty || [$0.title, $0.artist, $0.album].joined(separator: " ").localizedCaseInsensitiveContains(search) }.count.formatted()) recommendations")
            } else { Text("\(rows.count.formatted()) entries") }
            Spacer()
            if model.recording && !model.lastCheck.isEmpty { Text("Checked \(model.lastCheck)") }
            Button { NSWorkspace.shared.open(model.archive.folder) } label: { Label("Data folder", systemImage: "folder") }.buttonStyle(.link)
        }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            .padding(.horizontal, Interface.inset).padding(.vertical, 12)
    }
    private func export() {
        do { try model.archive.exportAll(); NSWorkspace.shared.activateFileViewerSelecting([model.archive.folder.appendingPathComponent("history.csv")]) }
        catch { model.error = error.localizedDescription }
    }
}

struct EmptyLibraryView: View {
    let searching: Bool
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : "music.note.list").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(searching ? "No matching songs" : title).font(.headline)
            Text(searching ? "Try another song, artist, or album." : detail).font(.subheadline).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
    }
}

struct SuggestionsView: View {
    @ObservedObject var model: Model
    let search: String
    @State private var showAlbumPreferences = false
    private var songs: [Recommendation] {
        model.suggestions.filter { search.isEmpty || [$0.title, $0.artist, $0.album].joined(separator: " ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("For you").font(.system(size: 23, weight: .semibold))
                    Text("Old favorites. Whole albums. A little discovery.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { model.nextForYou() } label: { Label("Next for you", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    .buttonStyle(.borderedProminent).disabled(model.playbackTrackID != nil)
                    .help("Add one recommended song without interrupting playback, then keep the queue going.")
                Button { model.refreshSuggestions(intent: .advance); model.refreshLibraryDetails(force: true); model.refreshMenuSong() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh recommendations").accessibilityLabel("Refresh recommendations")
                Menu {
                    Button("Album preferences…") { showAlbumPreferences = true }
                    Button("Undo last feedback") { model.undoFeedback() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("Recommendation options").accessibilityLabel("Recommendation options")
            }
            if model.automaticQueue.enabled {
                HStack {
                    Label(model.automaticQueue.waitingForAlbum ? "Auto queue waits until the album finishes" : "Auto queue is keeping one song ahead", systemImage: "text.line.first.and.arrowtriangle.forward")
                    Spacer()
                    Button("Stop auto queue") { model.stopAutomaticQueue() }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if model.libraryDetailsBusy { Label("Updating library details…", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(.secondary) }
            if !model.playbackError.isEmpty {
                Label(model.playbackError, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            } else if model.playbackTrackID != nil {
                Text("Updating Music…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !model.playbackMessage.isEmpty {
                Text(model.playbackMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(songs) { song in
                        RecommendationRow(model: model, song: song)
                        if song.id != songs.last?.id { Divider().padding(.leading, 72) }
                    }
                }.padding(.horizontal, 16)
            }.background(Interface.content, in: RoundedRectangle(cornerRadius: Interface.radius))
                .overlay {
                    if songs.isEmpty {
                        EmptyLibraryView(searching: !search.isEmpty, title: model.libraryDetailsBusy ? "Updating your library…" : "Find your next favorite", detail: model.libraryDetailsBusy ? "Recommendations will appear when the library is ready." : "Recommendations appear after importing history or recording a few listens.")
                    }
                }
        }.sheet(isPresented: $showAlbumPreferences) { AlbumPreferencesView(model: model) }
    }
}

struct RecommendationRow: View {
    @ObservedObject var model: Model
    let song: Recommendation
    var body: some View {
        HStack(spacing: 14) {
            MediaMark(album: song.kind == .album)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(song.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).help(song.title)
                    if song.kind == .album {
                        Text("ALBUM").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 3).background(Interface.canvas, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(song.kind == .album ? "\(song.artist) · \(song.trackIDs.count) saved tracks" : [song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(song.playbackIssue ?? song.reason).font(.system(size: 11))
                    .foregroundStyle(song.playbackIssue == nil ? Color.secondary : .orange).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            HStack(spacing: 8) {
                Button { model.play(song) } label: {
                    Label(model.playbackTrackID == song.id ? "Starting…" : song.kind == .album ? "Play album" : "Play", systemImage: "play.fill")
                        .frame(minWidth: 64)
                }.disabled(model.playbackTrackID != nil || song.playbackIssue != nil)
                    .accessibilityLabel("Play \(song.title) by \(song.artist) in Music")
                SongFeedbackButtons(title: song.title, feedback: model.songFeedback[song.id] ?? RecommendationFeedback(),
                    likeConfirmed: model.feedbackConfirmation?.isLike(for: song.id) == true,
                    like: { model.rate(song.id, "like") },
                    dislike: { model.rate(song.id, model.songFeedback[song.id]?.less == true ? "reset" : "less") })
                Menu {
                    Button("Not now") { model.rate(song.id, "later") }
                    Divider()
                    Button("Find in Music") {
                        var url = URLComponents(string: "https://music.apple.com/search")!
                        url.queryItems = [URLQueryItem(name: "term", value: song.title + " " + song.artist)]
                        if let link = url.url { NSWorkspace.shared.open(link) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("More actions for \(song.title)").accessibilityLabel("More actions for \(song.title)")
            }.fixedSize().controlSize(.regular)
        }.padding(.vertical, 17)
    }
}

struct AlbumPreferencesView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Album listening preferences").font(.system(size: 23, weight: .semibold))
            Text("Choose how you like to listen. Likes for individual songs remain separate.").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("Search albums or album artists", text: $search).textFieldStyle(.roundedBorder)
            List(model.albumOptions.filter { search.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) }) { album in
                HStack(spacing: 12) {
                    MediaMark(album: true, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title).fontWeight(.medium)
                        Text(album.artist).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Listening style", selection: Binding(get: { model.albumModes[album.id] ?? .automatic }, set: { model.setAlbumMode(album.id, $0) })) {
                        ForEach(AlbumListeningMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }.labelsHidden().frame(width: 190).accessibilityLabel("Listening style for \(album.title)")
                }.padding(.vertical, 7)
            }
            HStack {
                Button("Refresh library details") { model.refreshLibraryDetails(force: true) }.disabled(model.libraryDetailsBusy || model.recording)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 480).background(Interface.canvas)
    }
}

// The heading leaves the menu's standard commands as native NSMenuItems.
struct MenuHeading: View {
    let sample: Sample?
    let recording: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AM Track").font(.system(size: 12, weight: .semibold))
                Spacer()
                RecordingIndicator(recording: recording)
            }
            NowPlayingSummary(sample: sample, compact: true)
        }.padding(16).frame(width: Interface.menuWidth)
    }
}

// Keep the native menu commands and selection drawing, but use an opaque
// semantic material instead of sampling other windows behind the dropdown.
@MainActor func useSolidMenuBackground(in view: NSView) {
    if let effect = view as? NSVisualEffectView, effect.material == .menu {
        effect.material = .windowBackground
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    for child in view.subviews { useSolidMenuBackground(in: child) }
}

final class MenuHeadingHostingView: NSHostingView<MenuHeading> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Menu views attach only when opened. Do not change the system window.
        if let content = window?.contentView { useSolidMenuBackground(in: content) }
    }
}

// Keep the complete batch inside a five-row viewport so menu commands stay put.
final class MenuRecommendationsView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let songs: [Recommendation]
    private let feedback: [String: RecommendationFeedback]
    private let playbackBusy: Bool
    private let play: (Recommendation) -> Void
    let table = MenuRecommendationsTable()

    init(songs: [Recommendation], feedback: [String: RecommendationFeedback], playbackBusy: Bool, play: @escaping (Recommendation) -> Void) {
        self.songs = songs; self.feedback = feedback; self.playbackBusy = playbackBusy; self.play = play
        super.init(frame: NSRect(x: 0, y: 0, width: Interface.menuWidth, height: CGFloat(min(songs.count, 5)) * 44))
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = false
        scrollerStyle = .overlay
        borderType = .noBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recommendation"))
        column.minWidth = Interface.menuWidth
        column.width = Interface.menuWidth
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(activateClickedRow)
        table.activate = { [weak self] in
            guard let self else { return }
            self.activate(row: self.table.selectedRow)
        }
        table.setAccessibilityLabel("For you recommendations")
        table.frame = NSRect(x: 0, y: 0, width: Interface.menuWidth, height: CGFloat(songs.count) * 44)
        table.autoresizingMask = [.width]
        documentView = table
        table.reloadData()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { songs.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !playbackBusy && songs[row].playbackIssue == nil
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let song = songs[row]
        let cell = NSTableCellView()
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: song.kind == .album ? "square.stack" : "music.note", accessibilityDescription: song.kind == .album ? "Album" : "Song")
        symbol.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: song.title.replacingOccurrences(of: "\n", with: " "))
        let artist = NSTextField(labelWithString: song.artist.replacingOccurrences(of: "\n", with: " "))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        artist.font = .systemFont(ofSize: 11)
        let disabled = playbackBusy || song.playbackIssue != nil
        title.textColor = disabled ? .disabledControlTextColor : .labelColor
        artist.textColor = disabled ? .disabledControlTextColor : .secondaryLabelColor
        for label in [title, artist] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [symbol, title, artist] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        cell.textField = title; cell.imageView = symbol
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            symbol.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -22),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            artist.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            artist.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            artist.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
        cell.toolTip = song.title + " · " + song.artist + "\n" + (song.playbackIssue ?? song.reason)
        return cell
    }
    @objc private func activateClickedRow() { activate(row: table.clickedRow) }
    private func activate(row: Int) {
        guard songs.indices.contains(row), !playbackBusy, songs[row].playbackIssue == nil else { return }
        play(songs[row])
    }
}

final class MenuRecommendationsTable: NSTableView {
    var activate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.characters == " " { activate?() }
        else { super.keyDown(with: event) }
    }
}

// Fit by rendered width, including CJK and wide Latin glyphs. The complete title
// remains in the menu item's semantic title and tooltip.
func menuFittedText(_ text: String, font: NSFont, width: CGFloat) -> String {
    let singleLine = text.replacingOccurrences(of: "\n", with: " ")
    guard (singleLine as NSString).size(withAttributes: [.font: font]).width > width else { return singleLine }
    var characters = Array(singleLine)
    while !characters.isEmpty {
        characters.removeLast()
        let candidate = String(characters) + "…"
        if (candidate as NSString).size(withAttributes: [.font: font]).width <= width { return candidate }
    }
    return "…"
}

func menuRecommendationTitle(_ song: Recommendation, feedback: RecommendationFeedback? = nil) -> NSAttributedString {
    let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    let subtitleFont = NSFont.systemFont(ofSize: 11)
    let title = menuFittedText(song.title, font: titleFont, width: Interface.menuTextWidth)
    let preference = feedback?.less == true ? "Less like this · " : ""
    let detail = preference + song.artist + (song.kind == .album ? " · Album · \(song.trackIDs.count) tracks" : "")
    let result = NSMutableAttributedString(string: title, attributes: [.font: titleFont])
    result.append(NSAttributedString(string: "\n" + menuFittedText(detail, font: subtitleFont, width: Interface.menuTextWidth), attributes: [.font: subtitleFont]))
    return result
}


struct FeedbackConfirmation {
    let id = UUID()
    let title: String
    let kind: String
    var targetID: String? = nil
    func isLike(for target: String) -> Bool { kind == "like" && targetID == target }
    var message: String {
        switch kind {
        case "like": return "Liked: " + title
        case "less": return "Less like this: " + title
        case "later": return "Not now: " + title
        case "reset": return "Preference cleared: " + title
        default: return "Listening preference saved: " + title
        }
    }
    var symbol: String { kind == "like" ? "heart.fill" : kind == "less" ? "hand.thumbsdown.fill" : "checkmark.circle" }
    var color: Color { kind == "like" ? .pink : kind == "less" ? Color(nsColor: .systemBrown) : .secondary }
}

struct FeedbackMark: View {
    let feedback: RecommendationFeedback
    var body: some View {
        if feedback.less {
            Image(systemName: "hand.thumbsdown.fill")
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemBrown))
                .help("Less like this")
                .accessibilityLabel("Less like this")
        }
    }
}

struct SongFeedbackButtons: View {
    let title: String
    let feedback: RecommendationFeedback
    var likeConfirmed = false
    let like: () -> Void
    let dislike: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            feedbackButton(selected: likeConfirmed, symbol: "heart", color: .pink,
                label: likeConfirmed ? "Like sent for " + title : "Like " + title, action: like)
            feedbackButton(selected: feedback.less, symbol: "hand.thumbsdown", color: Color(nsColor: .systemBrown),
                label: feedback.less ? "Remove dislike for " + title : "Less like this: " + title, action: dislike)
        }.fixedSize()
    }
    private func feedbackButton(selected: Bool, symbol: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol + (selected ? ".fill" : ""))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? color : .secondary)
                .frame(width: 30, height: 28)
                .background(selected ? color.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.borderless)
            .help(label).accessibilityLabel(label).accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
