import AppKit
import SwiftUI
import SQLite3
import Darwin
import CryptoKit

let isoFormatter = ISO8601DateFormatter()
func stamp(_ date: Date = Date()) -> String { isoFormatter.string(from: date) }
func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
struct AppError: LocalizedError { let message: String; var errorDescription: String? { message } }
let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Archive {
    var handle: OpaquePointer?
    let folder: URL
    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("history.sqlite3").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw AppError(message: "Cannot open your history archive.")
        }
        chmod(path, 0o600)
        sqlite3_busy_timeout(handle, 2000)
        try exec("CREATE TABLE IF NOT EXISTS library_tracks (persistent_id TEXT PRIMARY KEY,title TEXT,artist TEXT,album TEXT,play_count INTEGER,last_played TEXT,first_observed_at TEXT,updated_at TEXT)")
        try exec("CREATE TABLE IF NOT EXISTS library_updates (id INTEGER PRIMARY KEY,persistent_id TEXT,title TEXT,artist TEXT,last_played TEXT,play_count INTEGER,count_delta INTEGER,observed_at TEXT,UNIQUE(persistent_id,last_played,play_count))")
        try exec("CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY,persistent_id TEXT,title TEXT,artist TEXT,album TEXT,first_observed_at TEXT,last_observed_at TEXT,ended_at TEXT,first_position REAL,last_position REAL,duration REAL,observed_listening_seconds REAL DEFAULT 0,start_reason TEXT,end_reason TEXT)")
        try exec("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT)")
        try exec("PRAGMA foreign_keys=ON")
        try migrate()
    }
    deinit { sqlite3_close(handle) }
    func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (index, value) in args.enumerated() {
            let i = Int32(index + 1)
            if let value = value as? String { sqlite3_bind_text(statement, i, value, Int32(value.utf8.count), transient) }
            else if let value = value as? NSNumber { sqlite3_bind_double(statement, i, value.doubleValue) }
            else { sqlite3_bind_null(statement, i) }
        }
        return statement
    }
    func failure() -> AppError { AppError(message: String(cString: sqlite3_errmsg(handle))) }
    func exec(_ sql: String, _ args: [Any?] = []) throws {
        let statement = try prepare(sql, args); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    func rows(_ sql: String, _ args: [Any?] = []) throws -> [[String: String]] {
        let statement = try prepare(sql, args); defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, i) {
                    row[String(cString: sqlite3_column_name(statement, i))] = String(decoding:UnsafeBufferPointer(start:value,count:Int(sqlite3_column_bytes(statement,i))),as:UTF8.self)
                }
            }
            rows.append(row)
        }
    }
    func meta(_ key: String, _ value: String) throws { try exec("INSERT OR REPLACE INTO metadata VALUES (?,?)", [key, value]) }
    func export(_ name: String, _ sql: String, _ columns: [String]) throws {
        func escape(_ string: String) -> String {
            var value = string
            if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let lines = try rows(sql).map { row in columns.map { escape(row[$0] ?? "") }.joined(separator: ",") }
        let content = "\u{FEFF}" + ([columns.joined(separator: ",")] + lines).joined(separator: "\r\n") + "\r\n"
        let url = folder.appendingPathComponent(name)
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            try content.write(to: url, atomically: true, encoding: .utf8); chmod(url.path, 0o600)
        }
    }
    func exportAll() throws {
        try syncRecordingsAndLibrary(includeLibrary:false)
        try exportUnifiedHistory()
        var status = Dictionary(uniqueKeysWithValues: try rows("SELECT * FROM metadata").map { ($0["key"]!, $0["value"] ?? "") })
        status["report_updated_at"] = stamp()
        try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("status.json"), options: .atomic)
        chmod(folder.appendingPathComponent("status.json").path, 0o600)
    }
}

struct Sample {
    var running = false
    var state = "closed"
    var title = ""
    var artist = ""
    var album = ""
    var key = ""
    var albumMetadata:[String:Any]=[:]
    var position: Double = 0
    var duration: Double = 0
    init(_ json: [String: Any]) {
        running = json["running"] as? Bool ?? false
        state = running ? (json["state"] as? String ?? "stopped") : "closed"
        title = json["title"] as? String ?? ""; artist = json["artist"] as? String ?? ""; album = json["album"] as? String ?? ""
        albumMetadata=json
        key = json["persistent_id"] as? String ?? ""
        if key.isEmpty { key = SHA256.hash(data: Data([title,artist,album].joined(separator: "\u{0}").utf8)).map { String(format:"%02x",$0) }.joined() }
        position = max(0,number(json["position"])); duration = number(json["duration"])
    }
}

final class Recorder {
    let archive: Archive
    var active: Int64?
    var previous: (sample: Sample, date: Date)?
    init(_ archive: Archive) throws {
        self.archive = archive
        try archive.exec("UPDATE sessions SET ended_at=last_observed_at,end_reason='recorder_interruption' WHERE ended_at IS NULL")
    }
    func finish(_ reason: String, at date: Date = Date()) throws {
        if let active { try archive.exec("UPDATE sessions SET ended_at=?,end_reason=? WHERE id=?", [stamp(date),reason,active]) }
        active = nil
    }
    func receive(_ sample: Sample, at date: Date = Date()) throws {
        var reason = "first_observed_playing"
        if ["stopped","closed"].contains(sample.state) { try finish(sample.state, at: date) }
        else if !sample.title.isEmpty {
            if let previous, active != nil {
                if date.timeIntervalSince(previous.date) > 15 { try finish("observation_gap",at:previous.date); reason="after_observation_gap" }
                else if previous.sample.key != sample.key { try finish("track_changed",at:date); reason="track_changed" }
                else if previous.sample.duration > 0 && previous.sample.position >= previous.sample.duration - 12 && sample.position < 10 && previous.sample.position - sample.position > 15 {
                    try finish("possible_replay_or_seek",at:date); reason="possible_replay_or_seek"
                }
            }
            if active == nil && sample.state == "playing" {
                try archive.exec("INSERT INTO sessions (persistent_id,title,artist,album,first_observed_at,last_observed_at,first_position,last_position,duration,start_reason) VALUES (?,?,?,?,?,?,?,?,?,?)", [sample.key,sample.title,sample.artist,sample.album,stamp(date),stamp(date),sample.position,sample.position,sample.duration,reason])
                active = sqlite3_last_insert_rowid(archive.handle)
            }
            if let active {
                var heard: Double = 0
                if let previous, previous.sample.key == sample.key && previous.sample.state == "playing" && sample.state == "playing" {
                    let elapsed = date.timeIntervalSince(previous.date), advanced = sample.position - previous.sample.position
                    if elapsed > 0 && elapsed <= 15 && advanced >= 0 && advanced <= elapsed + 2 { heard = min(elapsed,advanced) }
                }
                try archive.exec("UPDATE sessions SET last_observed_at=?,last_position=?,observed_listening_seconds=observed_listening_seconds+?,last_listening_at=CASE WHEN ?>0 THEN ? ELSE last_listening_at END WHERE id=?", [stamp(date),sample.position,heard,heard,stamp(date),active])
            }
        }
        previous = (sample,date)
        try archive.meta("last_successful_sample",stamp(date)); try archive.meta("player_state",sample.state)
        try archive.meta("current_title",sample.title)
    }
    func library(_ json: [String: Any]) throws { try archive.ingestLibrary(json) }
}

extension Archive {
    func ingestLibrary(_ json: [String: Any]) throws {
        guard json["running"] as? Bool == true, let tracks = json["tracks"] as? [[String:Any]] else { return }
        try self.exec("BEGIN IMMEDIATE")
        do {
            for track in tracks {
                guard let key = track["persistent_id"] as? String else { continue }
                let old = try self.rows("SELECT * FROM library_tracks WHERE persistent_id=?",[key]).first
                let date = track["last_played"] as? String, count = number(track["play_count"])
                if let old, let date, old["last_played"] != date || Double(old["play_count"] ?? "0") != count {
                    try self.exec("INSERT OR IGNORE INTO library_updates (persistent_id,title,artist,last_played,play_count,count_delta,observed_at) VALUES (?,?,?,?,?,?,?)", [key,track["title"],track["artist"],date,count,count - (Double(old["play_count"] ?? "0") ?? 0),stamp()])
                }
                try self.exec("INSERT INTO library_tracks VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(persistent_id) DO UPDATE SET title=excluded.title,artist=excluded.artist,album=excluded.album,play_count=excluded.play_count,last_played=excluded.last_played,updated_at=excluded.updated_at",[key,track["title"],track["artist"],track["album"],count,date,stamp(),stamp()])
                var song=ImportedSong(title:track["title"] as? String ?? "")
                song.artist=track["artist"] as? String ?? "";song.album=track["album"] as? String ?? ""
                song.persistentID=key;song.genre=track["genre"] as? String ?? "";song.duration=number(track["duration"])
                let id=try self.resolve(song)
                try self.saveAlbumMetadata(track,id:id)
            }
            try self.meta("last_library_refresh",stamp()); try self.exec("COMMIT")
        } catch { try? self.exec("ROLLBACK"); throw error }
    }
}

struct HistoryRow: Identifiable {
    let id: String; let trackID:String; let date: String; let title: String; let artist: String; let album: String; let amount: String; let detail: String
}

final class QueryControl {
    private let lock=NSLock()
    private var cancelled=false
    private var current: Process?
    func launch(_ process:Process) throws {
        lock.lock();defer { lock.unlock() }
        guard !cancelled else { throw AppError(message:"Recording stopped.") }
        try process.run();current=process
    }
    func terminate(_ process:Process) {
        lock.lock();defer { lock.unlock() }
        if current === process && process.isRunning { process.terminate() }
    }
    func cancel() {
        lock.lock();defer { lock.unlock() };cancelled=true
        if let current,current.isRunning { current.terminate() }
    }
}
func displayDate(_ string: String?) -> String {
    guard let string else { return "" }
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
    guard let date = isoFormatter.date(from:string) ?? fractional.date(from:string) else { return string }
    return date.formatted(date:.abbreviated,time:.shortened)
}

@MainActor final class Model: ObservableObject {
    let lease:ArchiveLease
    let archive: Archive
    @Published var recording = false
    @Published var sample: Sample?
    @Published var error = ""
    @Published var history:[HistoryRow]=[]
    @Published var suggestions:[Recommendation]=[]
    @Published var playbackTrackID:String?
    @Published var playbackMessage=""
    @Published var playbackError=""
    @Published var menuSample:Sample?
    @Published var albumOptions:[AlbumCollection]=[]
    @Published var albumModes:[String:AlbumListeningMode]=[:]
    @Published var libraryDetailsBusy=false
    @Published var libraryDetailsError=""
    @Published var historyStatus="History has not been checked yet"
    @Published var historyChecked=""
    @Published var historyProblem=""
    @Published var databaseStatus=""
    @Published var historyIsLive=false
    @Published var historySource=""
    @Published var selectedTab=0
    @Published var lastCheck = ""
    var onChange: (() -> Void)?
    var recorder: Recorder?
    var timer: Timer?
    var generation = 0
    var busy = false
    var nextLibrary = Date.distantPast
    var nextExport = Date.distantPast
    var nextAudit = Date.distantPast
    var historyBusy=false
    var historyGeneration=0
    var nextRecommendations=Date.distantPast
    var queryControl=QueryControl()
    let queryQueue = DispatchQueue(label:"org.amtrack.app.queries",qos:.utility)
    let playbackQueue = DispatchQueue(label:"org.amtrack.app.playback",qos:.userInitiated)
    let playbackControl=QueryControl()
    let menuSongControl=QueryControl()
    let menuSongQueue=DispatchQueue(label:"org.amtrack.app.menu-song",qos:.utility)
    var menuSongBusy=false
    var playedForYouIDs=Set<String>()
    @Published var automaticQueue=AutomaticQueue()
    var automaticQueueEpoch=0
    // Overrides are used only by isolated tests; production uses Music's native queue.
    var catalogResolveOverride:(([[String:Any]]) throws -> [CatalogQueueSong])?
    var queueAppendOverride:(([String:Any]) throws -> Int)?
    let libraryDetailsControl=QueryControl()
    var nextLibraryDetails=Date.distantPast
    init(folder: URL) throws {
        lease=try ArchiveLease(folder)
        archive=try Archive(folder:folder)
        try archive.exec("UPDATE sessions SET ended_at=last_observed_at,end_reason='recorder_interruption' WHERE ended_at IS NULL")
        try archive.meta("recorder_state","stopped");try archive.meta("recorder_pid","")
        try archive.syncRecordingsAndLibrary()
        let report=try archive.audit(full:true)
        guard report["database_ok"] as? Bool==true else { throw AppError(message:"Database checks failed. See database-health.json; recording has not started.") }
        databaseStatus="Database checks passed"
        if try archive.value("history_source_path").isEmpty {
            try archive.meta("history_source_path",folder.appendingPathComponent("History.dat").path)
        }
        historySource=try archive.value("history_source_path")
        historyIsLive=isLiveHistory(URL(fileURLWithPath:historySource))
        nextAudit=Date().addingTimeInterval(300)
        reload()
    }
    var status: String {
        if !recording { return "Recording is off" }
        if !error.isEmpty { return "Needs attention" }
        guard let sample else { return "Connecting to Music" }
        switch sample.state { case "playing":return "Recording playback"; case "paused":return "Music is paused"; case "closed":return "Waiting for Music"; default:return "Waiting for playback" }
    }
    func reload() {
        do {
            let albumArtists=Dictionary(uniqueKeysWithValues:try archive.rows("SELECT track_id,album_artist FROM track_album_metadata").map{($0["track_id"]!,$0["album_artist"] ?? "")})
            history=try archive.unifiedRows().map { row in
                let seconds=row["observed_listening_seconds"].flatMap(Double.init)
                let source=row["source"] ?? ""
                let method=row["match_method"] ?? ""
                let note=row["note"] ?? ""
                let detail=source + (method.contains("priority") ? " · sequence match" : method.contains("Likely") ? " · likely match" : "") + (note.isEmpty ? "" : " · "+note)
                let artist=albumArtists[row["track_id"] ?? ""] ?? ""
                return HistoryRow(id:row["id"]!,trackID:row["track_id"]!,date:row["first_observed_at"].map{displayDate($0)} ?? "Date unknown",title:row["title"] ?? "",artist:artist.isEmpty ? "Unknown album artist" : artist,album:row["album"] ?? "",amount:seconds.map{String(format:"%.0f sec",$0)} ?? "Unknown",detail:detail)
            }
            historyStatus=try archive.value("history_detail")
            historyChecked=displayDate(try archive.value("history_last_check"))
            if Date()>=nextRecommendations {
                suggestions=try archive.recommendations();nextRecommendations=Date().addingTimeInterval(30)
                try updateAlbumOptions()
            }
        } catch { self.error = error.localizedDescription }
        onChange?()
    }
    func start() {
        guard !recording else { return }
        do {
            recorder = try Recorder(archive)
            try archive.meta("recorder_state","running"); try archive.meta("recorder_pid",String(getpid()))
            error=""; recording=true; generation += 1; nextLibrary = .distantPast; nextExport = .distantPast;queryControl=QueryControl()
            timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in
                guard let model=self else { return }
                DispatchQueue.main.async { model.poll() }
            }
            poll(); onChange?()
        } catch { self.error=error.localizedDescription; onChange?() }
    }
    func stop() {
        guard recording else { return }
        timer?.invalidate();timer=nil; recording=false; generation += 1;queryControl.cancel()
        do {
            try recorder?.finish("recorder_stopped")
            try archive.meta("recorder_state","stopped");try archive.meta("recorder_pid","");try archive.exportAll()
        } catch { self.error=error.localizedDescription }
        recorder=nil; sample=nil; reload()
    }
    func chooseHistory() {
        let panel=NSOpenPanel();panel.title="Choose Music’s live History.dat"
        panel.message="Select History.dat for an optional check against recorded history. It is read only when you request a check. A copied file can also be checked."
        panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.treatsFilePackagesAsDirectories=true
        panel.directoryURL=FileManager.default.urls(for:.musicDirectory,in:.userDomainMask).first?.appendingPathComponent("Music/Music Library.musiclibrary/Preferences")
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do {
            // Validate before replacing a working source. Retain a bookmark for a user-selected file.
            _=try HistorySnapshot.read(url)
            let bookmark=try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
            try archive.meta("history_source_path",url.path);try archive.meta("history_source_bookmark",bookmark.base64EncodedString())
            historySource=url.path;historyIsLive=isLiveHistory(url);historyGeneration += 1
            checkHistory()
        } catch { historyProblem=error.localizedDescription;onChange?() }
    }
    func sourceURL() -> URL {
        if let text=try? archive.value("history_source_bookmark"),let data=Data(base64Encoded:text),!data.isEmpty {
            var stale=false
            if let url=try? URL(resolvingBookmarkData:data,options:[.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale) { return url }
        }
        return URL(fileURLWithPath:historySource)
    }
    func checkHistory() {
        guard !historyBusy else { return }
        historyBusy=true;let source=sourceURL(),token=historyGeneration
        queryQueue.async {
            let result=Result { try HistorySnapshot.read(source) }
            DispatchQueue.main.async {
                self.historyBusy=false
                guard token==self.historyGeneration else { self.checkHistory();return }
                do {
                    _=try self.archive.ingest(result.get())
                    try self.archive.syncRecordingsAndLibrary(includeLibrary:false);try self.archive.reconcile()
                    try self.archive.syncUnifiedHistory(preferMusic:true)
                    self.historyProblem=""
                    let state=try self.archive.value("history_state")
                    if state=="review" { self.historyProblem="Some history entries have an uncertain overlap. They are saved separately from play counts." }
                } catch {
                    self.historyProblem="History check failed. Saved entries are safe. \(error.localizedDescription)"
                    try? self.archive.logHistory("unavailable",self.historyProblem,source.path)
                }
                self.auditIfDue()
                self.nextRecommendations = .distantPast;self.reload()
            }
        }
    }
    func auditIfDue() {
        if Date()>=self.nextAudit {
            self.nextAudit=Date().addingTimeInterval(300)
            do {
                let report=try self.archive.audit()
                if report["database_ok"] as? Bool==true { self.databaseStatus="Database checks passed" }
                else { self.databaseStatus="Database needs attention";self.error="Database checks failed. Recording has stopped; see database-health.json.";self.stop() }
            } catch { self.databaseStatus="Database check failed";self.error=error.localizedDescription;self.stop() }
        }
    }
    func refreshSuggestions() {
        do { suggestions=try archive.recommendations(log:true);nextRecommendations=Date().addingTimeInterval(30);try updateAlbumOptions() }
        catch { self.error=error.localizedDescription }
    }
    func updateAlbumOptions() throws {
        albumOptions=try archive.albumCollections()
        let states=try archive.recommendationFeedback(now:Date())
        albumModes=Dictionary(uniqueKeysWithValues:albumOptions.map{($0.id,archive.albumMode($0,feedback:states))})
    }
    func setAlbumMode(_ id:String,_ mode:AlbumListeningMode) {
        rate(id,mode == .automatic ? "mode_auto" : mode == .album ? "mode_album" : "mode_tracks")
    }
    func refreshLibraryDetails(force:Bool=false) {
        guard !libraryDetailsBusy,!recording,(force || Date()>=nextLibraryDetails) else { return }
        libraryDetailsBusy=true;libraryDetailsError=""
        let control=libraryDetailsControl
        queryQueue.async {
            let result=Result { try Self.query("library",control:control) }
            DispatchQueue.main.async {
                self.libraryDetailsBusy=false
                do {
                    let json=try result.get()
                    guard json["running"] as? Bool == true else {
                        self.nextLibraryDetails=Date().addingTimeInterval(30);return
                    }
                    try self.archive.ingestLibrary(json)
                    self.nextLibraryDetails=Date().addingTimeInterval(300)
                    self.nextRecommendations = .distantPast;self.reload()
                } catch {
                    self.libraryDetailsError="Could not refresh Music library details: \(error.localizedDescription)"
                    self.nextLibraryDetails=Date().addingTimeInterval(60)
                }
            }
        }
    }
    func rate(_ id:String,_ kind:String) {
        do { try archive.feedback(id,kind);refreshSuggestions() }
        catch { self.error=error.localizedDescription }
    }
    func undoFeedback() {
        do { try archive.undoRecommendationFeedback();refreshSuggestions() }
        catch { self.error=error.localizedDescription }
    }
    func refreshMenuSong() {
        guard !menuSongBusy else { return };menuSongBusy=true
        let control=menuSongControl,epoch=automaticQueueEpoch
        menuSongQueue.async {
            let result=Result { Sample(try Self.query("sample",control:control)) }
            DispatchQueue.main.async {
                self.menuSongBusy=false
                if let current=try? result.get() {
                    self.menuSample=current
                    if epoch==self.automaticQueueEpoch { self.observeAutomaticQueue(current) }
                }
                self.onChange?()
            }
        }
    }
    func rateCurrent(_ current:Sample,_ kind:String) {
        do {
            try archive.feedbackForCurrentSong(current,kind)
            playbackError="";refreshSuggestions()
        } catch { playbackError=error.localizedDescription }
        onChange?()
    }
    func nextForYou() {
        guard playbackTrackID == nil else { return }
        playbackMessage="";playbackError=""
        addAutomaticSongs()
    }
    func stopAutomaticQueue() {
        automaticQueueEpoch += 1;automaticQueue.stop()
        playbackMessage="Automatic queue stopped. Songs already queued will keep playing."
        onChange?()
    }
    func observeAutomaticQueue(_ current:Sample) {
        guard playbackTrackID == nil else { return }
        automaticQueue.observe(current)
        replenishAutomaticQueue()
    }
    func replenishAutomaticQueue() {
        guard automaticQueue.enabled,!automaticQueue.waitingForAlbum,
              automaticQueue.pendingReplacements>0,playbackTrackID == nil else { return }
        automaticQueue.pendingReplacements -= 1
        addAutomaticSongs(limit:1,replenishing:true)
    }
    func addAutomaticSongs(limit:Int=5,replenishing:Bool=false) {
        do {
            let candidates=try archive.automaticQueueSongs(excluding:playedForYouIDs,currentPersistentID:menuSample?.musicPersistentID,limit:100,excludingPersistentIDs:automaticQueue.knownIDs)
            let requests=try candidates.map{try archive.queueRequest(for:$0.id)}
            guard !requests.isEmpty else { throw AppError(message:"No more eligible songs are available for the automatic queue.") }
            let control=playbackControl,prefix=replenishing ? "" : playbackMessage
            let epoch=automaticQueueEpoch,baseline=menuSample?.musicPersistentID
            let appendOverride=queueAppendOverride,resolveOverride=catalogResolveOverride
            playbackTrackID=candidates[0].id;onChange?()
            playbackQueue.async {
                var selected:[CatalogQueueSong]=[],added=0,failure:String?
                do {
                    if let resolveOverride { selected=Array(try resolveOverride(requests).prefix(limit)) }
                    else {
                        let argument=String(decoding:try JSONSerialization.data(withJSONObject:requests),as:UTF8.self)
                        selected=Array(try resolvedQueueSongs(Self.query("catalog",control:control,arguments:[argument,String(limit)]),requests:requests).prefix(limit))
                    }
                    guard !selected.isEmpty else { throw AppError(message:"These recommendations have no verified Apple Music catalog IDs. Refresh the library or download the songs in Music before trying again.") }
                    for entry in selected {
                        if let appendOverride { _=try appendOverride(["catalog_id":entry.catalogID]) }
                        else { try MusicQueue.append(catalogID:entry.catalogID,control:control) }
                        added += 1
                    }
                } catch { failure=error.localizedDescription }
                let chosen=selected,completed=added,problem=failure
                DispatchQueue.main.async {
                    self.playbackTrackID=nil
                    do {
                        let songs=chosen.map{candidates[$0.index]}
                        try self.completeAutomaticQueue(songs,addedCount:completed,prefix:prefix)
                        if epoch==self.automaticQueueEpoch {
                            let queued=chosen.prefix(completed).map{[$0.persistentID]}
                            if !self.automaticQueue.enabled && !replenishing && completed>0 {
                                self.automaticQueue.start(queued:queued,currentID:baseline)
                            } else if self.automaticQueue.enabled { self.automaticQueue.append(queued) }
                            if problem != nil { self.automaticQueue.stop() }
                        }
                    } catch { self.error=error.localizedDescription;self.automaticQueue.stop() }
                    if let problem { self.playbackError=problem }
                    self.onChange?();self.replenishAutomaticQueue();self.refreshMenuSong()
                }
            }
        } catch { playbackTrackID=nil;playbackError=error.localizedDescription;automaticQueue.stop();onChange?() }
    }
    func completeAutomaticQueue(_ songs:[Recommendation],addedCount:Int,prefix:String="") throws {
        guard addedCount>=0,addedCount<=songs.count,songs.allSatisfy({$0.kind == .song}) else {
            throw AppError(message:"Music returned an invalid automatic queue result.")
        }
        let added=Array(songs.prefix(addedCount))
        try archive.rememberForYouSelections(Set(added.flatMap{$0.trackIDs}))
        playedForYouIDs.formUnion(added.map{$0.id})
        playbackMessage=prefix+(prefix.isEmpty ? "" : " ")+"Added \(addedCount) recommended song\(addedCount == 1 ? "" : "s") to the end of the queue."
        refreshSuggestions()
    }
    func completeForYouQueue(_ song:Recommendation,addedCount:Int) throws {
        guard addedCount>0,addedCount<=song.trackIDs.count else { throw AppError(message:"Music did not confirm adding this selection.") }
        if addedCount==song.trackIDs.count { try archive.rememberForYouPlayback(song) }
        else { try archive.rememberForYouSelections(Set(song.trackIDs.prefix(addedCount))) }
        playedForYouIDs.insert(song.id)
        playbackMessage=addedCount==song.trackIDs.count ? "Added \(song.title) to Music’s queue\(song.kind == .album ? " · \(addedCount) songs in album order" : "")." : "Added \(addedCount) songs from \(song.title) to Music’s queue."
        refreshSuggestions()
    }
    func play(_ song:Recommendation) {
        guard playbackTrackID == nil else { return }
        playbackMessage="";playbackError=""
        do {
            let request=try archive.playbackRequest(for:song)
            let following=song.kind == .album ? try archive.automaticQueueSongs(excluding:playedForYouIDs.union(song.trackIDs),currentPersistentID:menuSample?.musicPersistentID,limit:100) : []
            let rest=song.kind == .album ? max(0,song.trackIDs.count-1) : 0
            let queueRequests=song.kind == .album ? try Array(song.trackIDs.dropFirst()).map{try archive.queueRequest(for:$0)}+following.map{try archive.queueRequest(for:$0.id)} : []
            let followingRequests=try following.map{try archive.playbackRequest(for:$0)}
            let first=(request["tracks"] as? [[String:Any]])?.first
            let ids=(request["ids"] as? [String]) ?? (first?["ids"] as? [String]) ?? []
            let control=playbackControl
            playbackTrackID=song.id;onChange?()
            playbackQueue.async {
                let result=Result { () throws -> [String:Any] in
                    var prepared=request,entries:[CatalogQueueSong]=[]
                    if song.kind == .album {
                        let argument=String(decoding:try JSONSerialization.data(withJSONObject:queueRequests),as:UTF8.self)
                        let resolved=try resolvedQueueSongs(Self.query("catalog",control:control,arguments:[argument,String(rest+5)]),requests:queueRequests)
                        let albumEntries=resolved.filter{$0.index<rest}
                        guard albumEntries.count==rest else { throw AppError(message:"A saved album song has no verified catalog ID for background queueing. The current playback was kept unchanged.") }
                        let after=Array(resolved.filter{$0.index>=rest}.prefix(5))
                        entries=albumEntries+after
                        try MusicQueue.checkAvailability(control:control)
                        prepared["native_queue"]=true
                        prepared["following_tracks"]=after.map{followingRequests[$0.index-rest]}
                    }
                    let argument=String(decoding:try JSONSerialization.data(withJSONObject:prepared),as:UTF8.self)
                    var response=try Self.query("play",control:control,arguments:[argument])
                    try confirmPlayback(response,requestedIDs:ids,albumCount:song.kind == .album ? song.trackIDs.count : nil)
                    if song.kind == .album {
                        guard response["pending_queue_ids"] as? [String]==entries.map({$0.persistentID}) else {
                            throw AppError(message:"Music changed the album's song identities before queueing. Automatic additions were stopped.")
                        }
                        var queued=0
                        for entry in entries {
                            do { try MusicQueue.append(catalogID:entry.catalogID,control:control);queued += 1 }
                            catch { response["queue_error"]=error.localizedDescription;break }
                        }
                        let added=Array(entries.prefix(queued).dropFirst(rest))
                        response["following_ids"]=added.map{$0.persistentID}
                        response["following_indices"]=added.map{$0.index-rest}
                    }
                    return response
                }
                DispatchQueue.main.async {
                    self.playbackTrackID=nil
                    do {
                        let response=try result.get()
                        try self.completeForYouPlayback(song,response:response,requestedIDs:ids)
                        self.automaticQueueEpoch += 1;self.automaticQueue.stop()
                        if song.kind == .album {
                            let appended=response["following_ids"] as? [String] ?? []
                            let indices=response["following_indices"] as? [Int] ?? []
                            guard indices.count==appended.count,indices.allSatisfy({following.indices.contains($0)}) else {
                                throw AppError(message:"Music did not confirm the album's following songs.")
                            }
                            let songs=indices.map{following[$0]}
                            try self.completeAutomaticQueue(songs,addedCount:songs.count,prefix:self.playbackMessage)
                            if let problem=response["queue_error"] as? String { self.playbackError="Automatic queue stopped: "+problem }
                            else { self.automaticQueue.start(queued:appended.map{[$0]},albumIDs:Set(response["album_ids"] as? [String] ?? [])) }
                            self.refreshMenuSong()
                        } else {
                            self.automaticQueue.start(queued:[],currentID:response["persistent_id"] as? String)
                            self.addAutomaticSongs()
                        }
                    } catch { self.playbackError=error.localizedDescription }
                    self.onChange?()
                }
            }
        } catch { playbackError=error.localizedDescription;onChange?() }
    }
    func completeForYouPlayback(_ song:Recommendation,response:[String:Any],requestedIDs:[String]) throws {
        try confirmPlayback(response,requestedIDs:requestedIDs,albumCount:song.kind == .album ? song.trackIDs.count : nil)
        if let playlist=response["playlist_id"] as? String { try archive.meta("album_playlist_id",playlist) }
        try archive.transaction {
            if song.kind == .song { try archive.feedback(song.id,"like") }
            try archive.rememberForYouPlayback(song)
        }
        playedForYouIDs.insert(song.id)
        playbackMessage=song.kind == .album ? "Started your saved songs from \(song.title) in album order." : "Started \(song.title) in Music."
        refreshSuggestions()
    }
    nonisolated static func query(_ script: String, control:QueryControl,arguments:[String]=[]) throws -> [String:Any] {
        guard let url=Bundle.main.url(forResource:script,withExtension:"js") else { throw AppError(message:"Missing Music reader.") }
        let process=Process(), output=Pipe(), errors=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript")
        process.arguments=["-l","JavaScript",url.path]+arguments;process.standardOutput=output;process.standardError=errors
        try control.launch(process)
        // Read stdout while the child runs; a library response can exceed a pipe's buffer.
        let deadline=DispatchWorkItem { control.terminate(process) }
        DispatchQueue.global().asyncAfter(deadline:.now()+35,execute:deadline)
        let data=output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit();deadline.cancel()
        guard process.terminationStatus == 0 else {
            let text=String(data:errors.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
            throw AppError(message:text.contains("1743") ? "Allow AM Track to control Music in System Settings > Privacy & Security > Automation." : (text.isEmpty ? "Music did not respond. Try again." : text.trimmingCharacters(in:.whitespacesAndNewlines)))
        }
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw AppError(message:"Music returned an unreadable response.") }
        return json
    }
    func poll() {
        guard recording && !busy else { return };busy=true
        let token=generation, readLibrary=Date() >= nextLibrary, control=queryControl
        queryQueue.async {
            let result=Result { try Self.query("sample",control:control) }
            let observedAt=Date()
            let musicOpen=(try? result.get()["running"] as? Bool) == true
            let libraryResult: Result<[String:Any],Error>? = readLibrary && musicOpen ? Result { try Self.query("library",control:control) } : nil
            DispatchQueue.main.async {
                self.busy=false
                guard self.recording && self.generation == token else { return }
                do {
                    let current=Sample(try result.get()); try self.recorder?.receive(current,at:observedAt);self.sample=current
                    self.lastCheck=Date().formatted(date:.omitted,time:.standard)
                    self.error=""
                    if let libraryResult {
                        try self.recorder?.library(try libraryResult.get());self.nextLibrary=Date().addingTimeInterval(300)
                    }
                    try self.archive.syncRecordingsAndLibrary(includeLibrary:false)
                    try self.archive.reconcile()
                    try self.archive.meta("last_error","")
                } catch {
                    self.error=error.localizedDescription
                    try? self.archive.meta("last_error",self.error)
                    if readLibrary { self.nextLibrary=Date().addingTimeInterval(60) }
                }
                self.auditIfDue()
                if Date() >= self.nextExport {
                    do { try self.archive.exportAll();self.nextExport=Date().addingTimeInterval(30) }
                    catch { self.error=error.localizedDescription }
                }
                self.reload()

            }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: Model
    var selected:Int { model.selectedTab }
    @State private var search=""
    var rows: [HistoryRow] {
        let all = model.history
        return search.isEmpty ? all : all.filter { [$0.title,$0.artist,$0.album].joined(separator:" ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.center,spacing:16) {
                Image(systemName:model.recording ? "waveform" : "music.note.list").font(.system(size:25,weight:.medium)).foregroundStyle(model.recording ? Color.accentColor : .secondary).frame(width:36)
                VStack(alignment:.leading,spacing:4) {
                    Text(model.status).font(.system(size:21,weight:.semibold))
                    Text(model.recording ? ((model.sample?.title.isEmpty == false ? model.sample!.title + " · " + model.sample!.albumArtistLabel : "Music playback will appear here")) : "Your saved history is here. Start recording whenever you’re ready.")
                        .font(.system(size:13)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength:12)
                Button(model.recording ? "Stop recording" : "Start recording") { model.recording ? model.stop() : model.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityHint("Controls this history recorder. Does not change Music playback.")
            }
            if !model.error.isEmpty {
                Label(model.error,systemImage:"exclamationmark.triangle").font(.system(size:12)).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack(spacing:16) {
                Picker("History",selection:$model.selectedTab) {
                    Text("History").tag(0);Text("For you").tag(4)
                }.pickerStyle(.segmented).frame(maxWidth:560).labelsHidden()
                Spacer(minLength:0)
                TextField("Search songs or artists",text:$search).textFieldStyle(.roundedBorder).frame(width:210).accessibilityLabel("Search history")
            }
            if selected == 0 {
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Label(model.historyIsLive ? "Live Music history selected" : "Saved history copy · optional cross-check",systemImage:model.historyIsLive ? "checkmark.circle" : "doc")
                    Spacer()
                    Button(model.historyBusy ? "Checking…" : "Check History.dat") { model.checkHistory() }.disabled(model.historyBusy)
                    Button("Choose History.dat…") { model.chooseHistory() }
                }
                Text(model.historyStatus.isEmpty ? "History check pending" : model.historyStatus).textSelection(.enabled)
                if !model.historyProblem.isEmpty { Label(model.historyProblem,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                Text(model.databaseStatus + (model.historyChecked.isEmpty ? "" : " · History checked \(model.historyChecked)") + " · History.dat checks are manual")
                    .foregroundStyle(.secondary)
            }.font(.system(size:12))
            }
            if selected == 4 {
                SuggestionsView(model:model,search:search)
            } else {
            Text("One merged history. Music’s checked sequence takes priority in matched stretches and fills recording gaps. Dates shown are recording observations; undated entries keep Music’s order.")
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Table(rows) {
                TableColumn("Observed",value:\.date).width(min:120,ideal:150,max:190)
                TableColumn("Song") { row in
                    Text(row.title).contextMenu {
                        Button("Like") { model.rate(row.trackID,"like") }
                        Button("Less like this") { model.rate(row.trackID,"less") }
                        Button("Not now") { model.rate(row.trackID,"later") }
                    }
                }.width(min:150,ideal:270)
                TableColumn("Album artist",value:\.artist).width(min:100,ideal:160)
                TableColumn("Listened") { row in Text(row.amount).monospacedDigit() }.width(min:65,ideal:80,max:90)
                TableColumn("Source / note") { row in Text(row.detail).foregroundStyle(.secondary) }.width(min:100,ideal:180)
            }
            .overlay {
                if rows.isEmpty {
                    VStack(spacing:8) {
                        Image(systemName:search.isEmpty ? "music.note" : "magnifyingglass").font(.system(size:26)).foregroundStyle(.secondary)
                        Text(search.isEmpty ? "No history here yet" : "No matching songs").font(.headline)
                        Text(search.isEmpty ? "New sessions appear while recording is on." : "Try another song or artist.").font(.subheadline).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
            }
            }
            HStack {
                Text("\((selected == 4 ? model.suggestions.count : rows.count).formatted()) \(selected == 4 ? "recommendations" : "entries")").monospacedDigit()
                if model.recording && !model.lastCheck.isEmpty { Text("· Checked \(model.lastCheck)") }
                Spacer()
                Button("Export history") {
                    do { try model.archive.exportAll();NSWorkspace.shared.activateFileViewerSelecting([model.archive.folder.appendingPathComponent("history.csv")]) }
                    catch { model.error=error.localizedDescription }
                }.buttonStyle(.link)
                Button("Open data folder") { NSWorkspace.shared.open(model.archive.folder) }.buttonStyle(.link)
            }.font(.system(size:12)).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth:840,minHeight:440).background(Color(nsColor:.windowBackgroundColor))
    }
}

struct SuggestionsView:View {
    @ObservedObject var model:Model
    let search:String
    @State private var showAlbumPreferences=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Old favorites, whole albums, and a little discovery.").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Next for you") { model.nextForYou() }.disabled(model.playbackTrackID != nil)
                    .help("Add five recommended songs, then keep filling after finishes and skips")
                Button("Album preferences…") { showAlbumPreferences=true }
                Button("Undo last feedback") { model.undoFeedback() }
                Button("Refresh") { model.refreshSuggestions();model.refreshLibraryDetails(force:true);model.refreshMenuSong() }
            }
            if model.automaticQueue.enabled {
                HStack {
                    Text(model.automaticQueue.waitingForAlbum ? "Auto queue · waiting until the album finishes" : "Auto queue · refills after finishes and skips")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop auto queue") { model.stopAutomaticQueue() }.controlSize(.small)
                }
            }
            if model.libraryDetailsBusy { Text("Updating album artists and track order from Music…").font(.caption).foregroundStyle(.secondary) }
            if !model.libraryDetailsError.isEmpty { Text(model.libraryDetailsError).font(.caption).foregroundStyle(.orange) }
            if let current=model.menuSample,current.musicPersistentID != nil {
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text("Now in Music · \(current.title)").font(.subheadline)
                        Text(current.albumArtistLabel+" · "+current.album).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Like") { model.rateCurrent(current,"like") }
                    Button("Less like this") { model.rateCurrent(current,"less") }
                }.padding(.vertical,8)
                Divider()
            }
            if !model.playbackError.isEmpty {
                Label(model.playbackError,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if model.playbackTrackID != nil {
                Text("Updating Music…").font(.caption).foregroundStyle(.secondary)
            } else if !model.playbackMessage.isEmpty {
                Text(model.playbackMessage).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:0) {
                    ForEach(model.suggestions.filter { search.isEmpty || [$0.title,$0.artist,$0.album].joined(separator:" ").localizedCaseInsensitiveContains(search) }) { song in
                        HStack(spacing:16) {
                            VStack(alignment:.leading,spacing:4) {
                                Text(song.title).font(.headline)
                                Text(song.kind == .album ? song.artist+" · Album · \(song.trackIDs.count) saved tracks" : song.artist+" · "+song.album).font(.subheadline).foregroundStyle(.secondary)
                                Text(song.reason).font(.caption).foregroundStyle(.secondary)
                                if let issue=song.playbackIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                            }.textSelection(.enabled)
                            Spacer()
                            Button { model.play(song) } label: {
                                Label(model.playbackTrackID == song.id ? "Starting…" : song.kind == .album ? "Play album" : "Play",systemImage:"play.fill")
                            }
                            .disabled(model.playbackTrackID != nil || song.playbackIssue != nil)
                            .accessibilityLabel("Play \(song.title) by \(song.artist) in Music")
                            .help(song.kind == .album ? "Play your saved songs from this album, in album order" : "Play this song from your Music library")
                            Button("Like") { model.rate(song.id,"like") }
                            Button("Not now") { model.rate(song.id,"later") }
                            Button("Less like this") { model.rate(song.id,"less") }
                            Button("Find in Music") {
                                var url=URLComponents(string:"https://music.apple.com/search")!
                                url.queryItems=[URLQueryItem(name:"term",value:song.title+" "+song.artist)]
                                if let link=url.url { NSWorkspace.shared.open(link) }
                            }
                        }.padding(.vertical,14)
                        Divider()
                    }
                }
                if model.suggestions.isEmpty { Text("Recommendations appear after importing history or recording a few listens.").foregroundStyle(.secondary).padding() }
            }
        }
        .sheet(isPresented:$showAlbumPreferences) { AlbumPreferencesView(model:model) }
    }
}

struct AlbumPreferencesView:View {
    @ObservedObject var model:Model
    @Environment(\.dismiss) private var dismiss
    @State private var search=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Album listening preferences").font(.title2)
            Text("Choose how you like to listen. Likes for individual songs remain separate.").foregroundStyle(.secondary)
            TextField("Search albums or album artists",text:$search).textFieldStyle(.roundedBorder)
            List(model.albumOptions.filter{search.isEmpty || ($0.title+" "+$0.artist).localizedCaseInsensitiveContains(search)}) { album in
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text(album.title)
                        Text(album.artist).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Listening style",selection:Binding(get:{model.albumModes[album.id] ?? .automatic},set:{model.setAlbumMode(album.id,$0)})) {
                        ForEach(AlbumListeningMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }.labelsHidden().frame(width:190)
                }.padding(.vertical,4)
            }
            HStack { Button("Refresh library details") { model.refreshLibraryDetails(force:true) }.disabled(model.libraryDetailsBusy || model.recording);Spacer();Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:720,height:500)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var model: Model!
    var item: NSStatusItem!
    var window: NSWindow!
    var menuSongTimer:Timer?
    var statusMenuIsOpen=false
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let arguments=CommandLine.arguments
            let folder: URL
            if let index=arguments.firstIndex(of:"--data-dir"),arguments.count > index+1 {
                folder=URL(fileURLWithPath:arguments[index+1],isDirectory:true)
            } else {
                let parent=Bundle.main.bundleURL.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath:parent.appendingPathComponent("history.sqlite3").path) {
                    folder=parent
                    UserDefaults.standard.set(folder.path,forKey:"archiveFolder")
                } else if let saved=UserDefaults.standard.string(forKey:"archiveFolder"),FileManager.default.fileExists(atPath:saved) {
                    folder=URL(fileURLWithPath:saved,isDirectory:true)
                } else {
                    folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AM Track",isDirectory:true)
                }
            }
            model=try Model(folder:folder)
            item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            model.onChange={ [weak self] in self?.updateMenu() }
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:680),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title="AM Track";window.minSize=NSSize(width:888,height:490);window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:HistoryView(model:model));window.center()
            createAppMenu();updateMenu();showHistory()
            model.refreshMenuSong()
            model.refreshLibraryDetails()
            menuSongTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
                guard let delegate=self else { return }
                DispatchQueue.main.async {
                    delegate.model.refreshLibraryDetails()
                    delegate.model?.refreshMenuSong()
                }
            }
            if arguments.contains("--record") { model.start() }

        } catch {
            let alert=NSAlert();alert.messageText="AM Track could not open your history";alert.informativeText=error.localizedDescription;alert.runModal();NSApp.terminate(nil)
        }
    }
    func createAppMenu() {
        let menu=NSMenu(),root=NSMenuItem(),app=NSMenu()
        menu.addItem(root);root.submenu=app
        app.addItem(withTitle:"Show app window",action:#selector(showHistory),keyEquivalent:"0").target=self
        app.addItem(.separator());app.addItem(withTitle:"Quit AM Track",action:#selector(quit),keyEquivalent:"q").target=self
        let editRoot=NSMenuItem(title:"Edit",action:nil,keyEquivalent:"");let edit=NSMenu(title:"Edit");editRoot.submenu=edit;menu.addItem(editRoot)
        for (title,action,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:action,keyEquivalent:key) }
        NSApp.mainMenu=menu
    }
    func updateMenu() {
        guard model != nil && item != nil else { return }
        let button=item.button!
        let needsCheck = !model.error.isEmpty || !model.historyProblem.isEmpty || !model.playbackError.isEmpty
        button.image=NSImage(systemSymbolName:needsCheck ? "exclamationmark.circle" : model.recording ? "waveform" : "music.note",accessibilityDescription:"AM Track")
        button.image?.isTemplate=true
        button.title = " " + (model.recording ? "On" : "Off")
        button.toolTip="AM Track: \(model.status)"
        // Keep recommendation rows stable beneath the pointer until the menu closes.
        guard !statusMenuIsOpen else { return }
        let menu=item.menu ?? NSMenu();menu.delegate=self;menu.autoenablesItems=false;menu.removeAllItems()
        @discardableResult func add(_ title:String,_ action:Selector?=nil,_ key:String="") -> NSMenuItem { let entry=menu.addItem(withTitle:title,action:action,keyEquivalent:key);entry.target=self;entry.isEnabled=action != nil;return entry }
        add("AM Track · \(model.status)")
        if let current=model.menuSample,!current.title.isEmpty { add(String(current.title.prefix(64)));add(String(current.albumArtistLabel.prefix(64))) }
        if !model.error.isEmpty { add(String(model.error.prefix(100))) }
        if !model.playbackError.isEmpty { add(String(model.playbackError.prefix(140))) }
        else if !model.playbackMessage.isEmpty { add(String(model.playbackMessage.prefix(140))) }
        menu.addItem(.separator());add(model.recording ? "Stop recording" : "Start recording",#selector(toggle))
        add("Show app window",#selector(showHistory),"0")
        menu.addItem(.separator())
        for (title,action) in [("Like",#selector(likeCurrent(_:))),("Less like this",#selector(lessLikeCurrent(_:)))] {
            let entry=add(title,action);entry.representedObject=model.menuSample
            entry.isEnabled=model.menuSample?.musicPersistentID != nil
        }
        let nextEntry=add(model.playbackTrackID == nil ? "Next for you" : "Updating Music…",#selector(nextForYou))
        nextEntry.isEnabled=model.playbackTrackID == nil
        nextEntry.toolTip="Add five recommended songs and keep filling the queue after finishes or skips."
        if model.automaticQueue.enabled { add("Stop auto queue",#selector(stopAutomaticQueue)) }
        menu.addItem(.separator())
        add("For you · Click to play")
        if model.suggestions.isEmpty { add("No recommendations yet") }
        for song in model.suggestions {
            let label=song.title+" · "+song.artist+(song.kind == .album ? " · Album (\(song.trackIDs.count) saved tracks)" : "")
            let entry=add(label,#selector(playRecommendation(_:)))
            entry.representedObject=song
            entry.image=NSImage(systemSymbolName:song.kind == .album ? "square.stack" : "music.note",accessibilityDescription:song.kind == .album ? "Album" : "Song")
            entry.image?.isTemplate=true
            entry.toolTip=song.playbackIssue ?? (song.kind == .album ? "Play your saved songs in album order. " : "Play this library song. ")+song.reason
            entry.isEnabled=model.playbackTrackID == nil && song.playbackIssue == nil
        }
        item.menu=menu
    }
    func menuWillOpen(_ menu:NSMenu) {
        if Date()>=model.nextRecommendations { model.reload() }
        updateMenu();statusMenuIsOpen=true
        model.refreshMenuSong()
    }
    func menuDidClose(_ menu:NSMenu) {
        statusMenuIsOpen=false
        DispatchQueue.main.async { [weak self] in self?.updateMenu() }
    }
    @objc func playRecommendation(_ sender:NSMenuItem) {
        if let song=sender.representedObject as? Recommendation { model.play(song) }
    }
    @objc func likeCurrent(_ sender:NSMenuItem) { if let current=sender.representedObject as? Sample { model.rateCurrent(current,"like") } }
    @objc func lessLikeCurrent(_ sender:NSMenuItem) { if let current=sender.representedObject as? Sample { model.rateCurrent(current,"less") } }
    @objc func nextForYou() { model.nextForYou() }
    @objc func stopAutomaticQueue() { model.stopAutomaticQueue() }
    @objc func showHistory() { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    @objc func toggle() { model.recording ? model.stop() : model.start() }
    @objc func showSuggestions() { model.selectedTab=4;showHistory() }
    @objc func checkHistory() { model.checkHistory() }
    @objc func chooseHistory() { model.chooseHistory() }
    @objc func openFolder() { NSWorkspace.shared.open(model.archive.folder) }
    @objc func quit() { model.libraryDetailsControl.cancel();model.menuSongControl.cancel();model.playbackControl.cancel();model.stop();NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) { menuSongTimer?.invalidate();model?.libraryDetailsControl.cancel();model?.menuSongControl.cancel();model?.playbackControl.cancel();model?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { showHistory();return true }
}

func selfTest() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let db=try Archive(folder:folder), recorder=try Recorder(db)
    func sample(_ key:String="A",_ position:Double=0,_ state:String="playing")->Sample {
        Sample(["running":true,"state":state,"title":"Song "+key,"artist":"Artist","persistent_id":key,"position":position,"duration":100])
    }
    for (time,position,state) in [(100.0,0.0,"playing"),(105,5,"playing"),(110,5,"paused"),(115,5,"paused"),(120,5,"playing"),(125,10,"playing"),(130,60,"playing"),(135,20,"playing"),(140,25,"playing")] {
        try recorder.receive(sample("A",position,state),at:Date(timeIntervalSince1970:time))
    }
    var rows=try db.rows("SELECT * FROM sessions")
    assert(rows.count==1 && Double(rows[0]["observed_listening_seconds"]!)==15,"Pause/seek handling")
    try recorder.receive(sample("B",97),at:Date(timeIntervalSince1970:145))
    try recorder.receive(sample("B",2),at:Date(timeIntervalSince1970:150))
    rows=try db.rows("SELECT * FROM sessions ORDER BY id")
    assert(rows.count==3 && rows[2]["start_reason"]=="possible_replay_or_seek","Repeat handling")
    try recorder.receive(sample("B",50),at:Date(timeIntervalSince1970:200))
    let gapRows=try db.rows("SELECT * FROM sessions")
    assert(gapRows.count==4,"Observation gap")
    try recorder.finish("recorder_stopped")
    let openRows=try db.rows("SELECT * FROM sessions WHERE ended_at IS NULL")
    assert(openRows.isEmpty,"Stop closes sessions")
    let track:[String:Any] = ["persistent_id":"C","title":"=Title, quoted \"中\"","artist":"Artist","album":"Album","play_count":5,"last_played":"2026-01-01T00:00:00Z"]
    try recorder.library(["running":true,"tracks":[track]])
    let baselineUpdates=try db.rows("SELECT * FROM library_updates")
    assert(baselineUpdates.isEmpty,"Baseline is not an event")
    var updated=track;updated["play_count"]=7;updated["last_played"]="2026-01-02T00:00:00Z"
    try recorder.library(["running":true,"tracks":[updated]]);try recorder.library(["running":true,"tracks":[updated]])
    let updates=try db.rows("SELECT * FROM library_updates")
    assert(updates.count==1 && updates[0]["count_delta"]=="2","Library deduplication")
    try db.exportAll()
    try db.export("escaping-test.csv","SELECT * FROM library_tracks",["title","artist","album"])
    let csv=try String(contentsOf:folder.appendingPathComponent("escaping-test.csv"),encoding:.utf8)
    assert(csv.contains("'=Title") && csv.contains("\"\"中\"\""),"CSV escaping")
    print("PASS: pause/resume, seeks, song changes, replay ambiguity, observation gaps, stop, library updates, CSV escaping.")
}

@main struct AMTrackApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest();try historyTests();try manualHistoryTests();try unifiedHistoryTests();try playbackTests();try forYouRefreshTests();try musicQueueTests();try automaticQueueTests();try recommendationTests();try recommendationMigrationTests() } catch { fputs("Self-test failed: \(error)\n",stderr);exit(1) }
        } else if CommandLine.arguments.contains("--queue-access-status") {
            print("Queue backend: MediaPlaybackCore background insertion; no Accessibility permission required")
        } else if CommandLine.arguments.contains("--upgrade-only") {
            do {
                guard let i=CommandLine.arguments.firstIndex(of:"--data-dir"),CommandLine.arguments.count>i+1 else { throw AppError(message:"Upgrade needs --data-dir.") }
                try upgradeOnly(URL(fileURLWithPath:CommandLine.arguments[i+1],isDirectory:true))
            } catch { fputs("Upgrade failed: \(error)\n",stderr);exit(1) }
        } else if CommandLine.arguments.contains("--maintain") {
            do {
                guard let i=CommandLine.arguments.firstIndex(of:"--data-dir"),CommandLine.arguments.count>i+1 else { throw AppError(message:"Maintenance needs --data-dir with an archive folder.") }
                try maintenance(URL(fileURLWithPath:CommandLine.arguments[i+1],isDirectory:true))
            } catch { fputs("Maintenance failed: \(error)\n",stderr);exit(1) }
        } else {
            let app=NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate=AppDelegate();app.delegate=delegate;app.run()
        }
    }
}
