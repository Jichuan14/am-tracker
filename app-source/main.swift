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
    func checkCancellation() throws {
        lock.lock();defer{lock.unlock()}
        guard !cancelled else { throw AppError(message:"Playback preparation cancelled.") }
    }
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
    @Published var collectionEnabled = false
    @Published var showSetup = false
    @Published var sample: Sample?
    @Published var error = ""
    @Published var history:[HistoryRow]=[]
    @Published var monthly=MonthlySnapshot()
    var openMonthlyRecap: (() -> Void)?
    @Published var suggestions:[Recommendation]=[]
    @Published var playbackTrackID:String?
    @Published var playbackMessage=""
    @Published var playbackError=""
    @Published var songFeedback:[String:RecommendationFeedback]=[:]
    @Published var currentSongFeedback=RecommendationFeedback()
    @Published var feedbackConfirmation:FeedbackConfirmation? {
        didSet {
            guard let confirmation=feedbackConfirmation else { return }
            DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
                // An older receipt must not dismiss feedback from a later click.
                guard let self,self.feedbackConfirmation?.id==confirmation.id else { return }
                self.feedbackConfirmation=nil
                self.onChange?()
            }
        }
    }
    @Published var menuSample:Sample? {
        didSet { currentSongFeedback=menuSample.map { feedback(for:$0) } ?? RecommendationFeedback() }
    }
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
    var playbackSelectionControl=QueryControl()
    let menuSongControl=QueryControl()
    let menuSongQueue=DispatchQueue(label:"org.amtrack.app.menu-song",qos:.utility)
    var menuSongBusy=false
    var menuSongPending=false
    var menuSongRequest=0
    var playbackReadOverride:(() throws -> [String:Any])?
    lazy var queueLatency=QueueLatencyTrace(folder:archive.folder)
    let suggestionQueue=DispatchQueue(label:"org.amtrack.app.suggestions",qos:.utility)
    var suggestionRequest=0
    var suggestionAdvancePending=false
    var playedForYouIDs=Set<String>()
    @Published var automaticQueue=AutomaticQueue()
    var automaticQueueEpoch=0
    var playbackSelectionRequest=0
    var preparedAutomaticSongs:[PreparedAutomaticSong]=[]
    var automaticPreparationBusy=false
    var automaticPreparationRequest=0
    var automaticInsertionRequest=0
    var automaticActiveInsertion:Int?
    var automaticInFlight:PreparedAutomaticSong?
    var automaticDeferredSample:Sample?
    var automaticCandidates:[AutomaticCandidate]=[]
    var automaticResolvingCandidates:[AutomaticCandidate]=[]
    var automaticExcludedIDs=Set<String>()
    var automaticRankingBusy=false
    var automaticRankingScheduled=false
    var automaticRankingRequest=0
    var automaticRankingError=""
    let automaticRankingQueue=DispatchQueue(label:"org.amtrack.app.rank-next-batch",qos:.utility)
    var automaticScoreOverride:((RecommendationSnapshot)->[Recommendation])?
    var automaticPreparationError=""
    var automaticPreparationControl=QueryControl()
    let automaticPreparationQueue=DispatchQueue(label:"org.amtrack.app.prepare-next",qos:.utility)
    // Overrides are used only by isolated tests; production uses Music's native queue.
    var catalogResolveOverride:(([[String:Any]]) throws -> [CatalogQueueSong])?
    var queueAppendOverride:(([String:Any]) throws -> Int)?
    var playbackStartOverride:(([String:Any]) throws -> [String:Any])?
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
        collectionEnabled = try archive.value("collection_consent") == "yes"
        showSetup = !collectionEnabled
        if try archive.value("history_source_path").isEmpty {
            try archive.meta("history_source_path",folder.appendingPathComponent("History.dat").path)
        }
        historySource=try archive.value("history_source_path")
        historyIsLive=isLiveHistory(URL(fileURLWithPath:historySource))
        nextAudit=Date().addingTimeInterval(300)
        reload()
    }
    var resumeRecordingOnLaunch:Bool {
        collectionEnabled && (try? archive.value("record_on_launch")) == "yes"
    }
    @discardableResult func requireCollectionConsent() -> Bool {
        guard collectionEnabled else { showSetup=true;onChange?();return false }
        return true
    }
    func allowCollection(recordOnLaunch:Bool) throws {
        try archive.transaction {
            try archive.meta("collection_consent","yes")
            try archive.meta("record_on_launch",recordOnLaunch ? "yes" : "no")
        }
        collectionEnabled=true;showSetup=false;onChange?()
    }
    func finishSetup() {
        do { try allowCollection(recordOnLaunch:true);start() }
        catch { self.error=error.localizedDescription }
    }
    func openAutomationSettings() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }
    var status: String {
        if !collectionEnabled { return "Music access is not enabled" }
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
            let monthlySnapshot=try archive.monthlySnapshot()
            if monthly != monthlySnapshot { monthly=monthlySnapshot }
            try refreshFeedback()
            historyStatus=try archive.value("history_detail")
            historyChecked=displayDate(try archive.value("history_last_check"))
            if Date()>=nextRecommendations {
                refreshSuggestions(background:true)
            }
        } catch { self.error = error.localizedDescription }
        onChange?()
    }
    func start() {
        guard requireCollectionConsent(),!recording else { return }
        do {
            try archive.meta("record_on_launch","yes")
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
    func stop(remember:Bool=true) {
        guard recording else { return }
        if remember { try? archive.meta("record_on_launch","no") }
        timer?.invalidate();timer=nil; recording=false; generation += 1;queryControl.cancel()
        do {
            try recorder?.finish("recorder_stopped")
            try archive.meta("recorder_state","stopped");try archive.meta("recorder_pid","");try archive.exportAll()
        } catch { self.error=error.localizedDescription }
        recorder=nil; sample=nil; reload()
    }
    func chooseHistory() {
        guard requireCollectionConsent() else { return }
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
        guard requireCollectionConsent() else { return }
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
    func refreshSuggestions(background:Bool=true,intent:RecommendationRefreshIntent = .revalidate) {
        if intent == .advance { suggestionAdvancePending=true }
        suggestionRequest += 1
        let request=suggestionRequest
        do {
            let snapshot=try archive.forYouSnapshot(intent:suggestionAdvancePending ? .advance : .revalidate)
            try updateAlbumOptions()
            nextRecommendations=Date().addingTimeInterval(30)
            if !background {
                try acceptSuggestions(snapshot.forYouResult(),request:request,at:snapshot.now)
                return
            }
            suggestionQueue.async {
                let result=snapshot.forYouResult()
                DispatchQueue.main.async {
                    do { try self.acceptSuggestions(result,request:request,at:snapshot.now) }
                    catch { self.error=error.localizedDescription;self.onChange?() }
                }
            }
        } catch { self.error=error.localizedDescription }
    }
    func acceptSuggestions(_ result:RecommendationRotationResult,request:Int,at now:Date) throws {
        // Check on the archive/main owner, and commit before publishing either list or generation.
        guard request==suggestionRequest else { return }
        try archive.commitForYouResult(result,at:now)
        suggestions=result.items;suggestionAdvancePending=false
        onChange?()
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
        guard collectionEnabled,!libraryDetailsBusy,!recording,(force || Date()>=nextLibraryDetails) else { return }
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
    func feedback(for current:Sample) -> RecommendationFeedback {
        guard let persistentID=current.musicPersistentID,
              let id=(try? archive.rows("SELECT track_id FROM track_aliases WHERE kind='persistent' AND value=?",[persistentID]))?.first?["track_id"] else { return RecommendationFeedback() }
        return songFeedback[id] ?? RecommendationFeedback()
    }
    func refreshFeedback() throws {
        songFeedback=try archive.recommendationFeedback(now:Date())
        currentSongFeedback=menuSample.map { feedback(for:$0) } ?? RecommendationFeedback()
    }
    func rate(_ id:String,_ kind:String) {
        do {
            let title=suggestions.first{$0.id==id}?.title ?? history.first{$0.trackID==id}?.title ?? albumOptions.first{$0.id==id}?.title ?? (try? archive.rows("SELECT title FROM music_tracks WHERE id=?",[id]))?.first?["title"] ?? "Selection"
            try archive.feedback(id,kind)
            try refreshFeedback()
            feedbackConfirmation=FeedbackConfirmation(title:title,kind:kind,targetID:id)
            refreshSuggestions();onChange?()
        } catch { self.error=error.localizedDescription }
    }
    func undoFeedback() {
        do {
            try archive.undoRecommendationFeedback()
            try refreshFeedback()
            feedbackConfirmation=nil
            refreshSuggestions();onChange?()
        } catch { self.error=error.localizedDescription }
    }
    func refreshMenuSong(notification:Bool=false) {
        guard collectionEnabled else { return }
        let epoch=automaticQueueEpoch
        if menuSongBusy {
            menuSongPending=true
            queueLatency.record("read_coalesced",epoch:epoch,request:menuSongRequest)
            return
        }
        menuSongBusy=true;menuSongPending=false;menuSongRequest += 1
        let request=menuSongRequest,control=menuSongControl,override=playbackReadOverride
        let trace=queueLatency,start=QueueLatencyTrace.now()
        trace.record(notification ? "notification_read" : "poll_read",epoch:epoch,request:request)
        menuSongQueue.async {
            let result=Result { Sample(try override?() ?? Self.query("playback",control:control)) }
            trace.record("read_complete",epoch:epoch,request:request,since:start)
            DispatchQueue.main.async {
                guard request==self.menuSongRequest else { return }
                self.menuSongBusy=false
                if epoch==self.automaticQueueEpoch,let current=try? result.get() {
                    self.menuSample=current
                    self.observeAutomaticQueue(current)
                } else if epoch != self.automaticQueueEpoch { self.menuSongPending=true }
                // A notification received while reading is never lost behind the poll timer.
                let trailing=self.menuSongPending
                self.menuSongPending=false
                if trailing { self.refreshMenuSong() }
                self.onChange?()
            }
        }
    }
    func rateCurrent(_ current:Sample,_ kind:String) {
        do {
            try archive.feedbackForCurrentSong(current,kind)
            try refreshFeedback()
            feedbackConfirmation=FeedbackConfirmation(title:current.title,kind:kind,targetID:"persistent:"+(current.musicPersistentID ?? ""))
            playbackError="";refreshSuggestions()
        } catch { playbackError=error.localizedDescription }
        onChange?()
    }
    func completeAutomaticQueue(_ songs:[Recommendation],addedCount:Int,prefix:String="",refresh:Bool=true) throws {
        guard addedCount>=0,addedCount<=songs.count,songs.allSatisfy({$0.kind == .song}) else {
            throw AppError(message:"Music returned an invalid automatic queue result.")
        }
        let added=Array(songs.prefix(addedCount))
        try archive.rememberForYouSelections(Set(added.flatMap{$0.trackIDs}))
        playedForYouIDs.formUnion(added.map{$0.id})
        playbackMessage=prefix+(prefix.isEmpty ? "" : " ")+"Queued \(addedCount) recommended song\(addedCount == 1 ? "" : "s") next."
        if refresh { refreshSuggestions(background:true) }
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
        guard requireCollectionConsent() else { return }
        guard playbackTrackID == nil else { return }
        let clickCache=suggestions // Capture before any UI refresh can replace this batch.
        resetAutomaticPreparation()
        playbackMessage="";playbackError=""
        do {
            let request=try archive.playbackRequest(for:song)
            let tracks=request["tracks"] as? [[String:Any]] ?? []
            let ids=(request["ids"] as? [String]) ?? (tracks.first?["ids"] as? [String]) ?? []
            let selectedIDs=Set(tracks.flatMap{$0["ids"] as? [String] ?? []}).union(ids)
            let excluded=playedForYouIDs.union(song.trackIDs).union([song.id])
            let candidates=try archive.cachedAutomaticCandidates(from:clickCache,excluding:excluded,currentPersistentID:menuSample?.musicPersistentID,knownIDs:selectedIDs)
            queueLatency.record("selection_cache_reserved",epoch:automaticQueueEpoch,cache:candidates.count)
            // A genuinely empty cache needs an asynchronous fallback; a nonempty
            // click reserve never waits for a new 100-item ranking before playback.
            let fallback=song.kind == .album && candidates.isEmpty ? try archive.automaticCandidateSnapshot() : nil
            let control=playbackSelectionControl,epoch=automaticQueueEpoch,score=automaticScoreOverride
            let resolve=catalogResolveOverride,start=playbackStartOverride,trace=queueLatency
            playbackSelectionRequest += 1
            let selectionRequest=playbackSelectionRequest
            playbackTrackID=song.id;onChange?()
            playbackQueue.async {
                let result=Result { () throws -> [String:Any] in
                    var prepared=request,following=candidates,entries:[CatalogQueueSong]=[]
                    if let fallback {
                        let began=QueueLatencyTrace.now()
                        let ranked=fallback.candidates(excluding:excluded,persistentIDs:selectedIDs,score:score)
                        trace.record("album_empty_cache_scoring",epoch:epoch,request:selectionRequest,since:began)
                        try control.checkCancellation()
                        // No control/SQLite lock is held here, and main never waits for
                        // playbackQueue. Re-enter the archive owner after long scoring.
                        following=try DispatchQueue.main.sync {
                            guard epoch==self.automaticQueueEpoch,selectionRequest==self.playbackSelectionRequest else { throw AppError(message:"Playback preparation cancelled.") }
                            return try self.archive.cachedAutomaticCandidates(from:ranked.map{$0.recommendation},excluding:self.playedForYouIDs.union(song.trackIDs).union([song.id]),currentPersistentID:self.menuSample?.musicPersistentID,knownIDs:selectedIDs)
                        }
                    }
                    try control.checkCancellation()
                    if song.kind == .album {
                        let requests=following.map{$0.request}
                        if !requests.isEmpty {
                            if let resolve { entries=Array(try resolve(requests).prefix(1)) }
                            else {
                                let argument=String(decoding:try JSONSerialization.data(withJSONObject:requests),as:UTF8.self)
                                entries=Array(try resolvedQueueSongs(Self.query("catalog",control:control,arguments:[argument,"1"]),requests:requests).prefix(1))
                            }
                        }
                        if let entry=entries.first {
                        guard following.indices.contains(entry.index) else { throw AppError(message:"Music returned an invalid album follow-up.") }
                        try control.checkCancellation()
                        // Catalog resolution can also outlive a feedback change. Check
                        // its exact mapping on the archive owner before issuing play.
                        let eligible=try DispatchQueue.main.sync {
                            guard epoch==self.automaticQueueEpoch,selectionRequest==self.playbackSelectionRequest else { throw AppError(message:"Playback preparation cancelled.") }
                            return try self.archive.automaticSongIsEligible(PreparedAutomaticSong(recommendation:following[entry.index].recommendation,entry:entry),excluding:self.playedForYouIDs.union(song.trackIDs).union([song.id]),currentPersistentID:self.menuSample?.musicPersistentID,knownIDs:selectedIDs)
                        }
                        guard eligible else { throw AppError(message:"The album's recommended follow-up changed while preparing playback. Refresh For you and try again.") }
                        prepared["following_tracks"]=[["kind":"song","ids":following[entry.index].request["ids"] as? [String] ?? []]]
                        } else {
                            prepared["following_tracks"]=[] as [[String:Any]]
                        }
                    }
                    try control.checkCancellation()
                    let argument=String(decoding:try JSONSerialization.data(withJSONObject:prepared),as:UTF8.self)
                    var response=try start?(prepared) ?? Self.query("play",control:control,arguments:[argument])
                    try confirmPlayback(response,requestedIDs:ids,albumCount:song.kind == .album ? song.trackIDs.count : nil)
                    if song.kind == .album {
                        guard response["following_ids"] as? [String]==entries.map({$0.persistentID}) else { throw AppError(message:"Music did not confirm the album's following song. Automatic queueing was stopped.") }
                        if let entry=entries.first {
                        response["prepared_songs"]=[PreparedAutomaticSong(recommendation:following[entry.index].recommendation,entry:entry)]
                        response["following_candidates"]=Array(following.dropFirst(entry.index+1))
                        }
                    }
                    return response
                }
                DispatchQueue.main.async {
                    guard selectionRequest==self.playbackSelectionRequest else { return }
                    self.playbackTrackID=nil
                    guard epoch==self.automaticQueueEpoch else { return }
                    do {
                        let response=try result.get()
                        try self.completeForYouPlayback(song,response:response,requestedIDs:ids)
                        if song.kind == .album {
                            let prepared=response["prepared_songs"] as? [PreparedAutomaticSong] ?? []
                            if let first=prepared.first {
                                let albumMessage=self.playbackMessage
                                try self.completeAutomaticQueue([first.recommendation],addedCount:1,refresh:false)
                                self.playbackMessage=albumMessage+" One recommended song follows the album."
                            }
                            if prepared.first != nil {
                                self.startAlbumAutomaticQueue(first:prepared.first,following:[],albumIDs:Set(response["album_ids"] as? [String] ?? []),candidates:response["following_candidates"] as? [AutomaticCandidate] ?? [],excluding:Set(song.trackIDs+[song.id]))
                            } else {
                                self.resetAutomaticPreparation()
                                self.playbackMessage += " No eligible follow-up song is available."
                            }
                            self.refreshMenuSong()
                        } else {
                            self.startAutomaticQueue(currentID:response["persistent_id"] as? String,cached:candidates.map{$0.recommendation},excluding:Set(song.trackIDs+[song.id]))
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
        // Accepting a recommendation is not an explicit preference; only the Like action writes feedback.
        try archive.rememberForYouPlayback(song)
        playedForYouIDs.insert(song.id)
        playbackMessage=song.kind == .album ? "Started your saved songs from \(song.title) in album order." : "Started \(song.title) in Music."
        DispatchQueue.main.async { self.refreshSuggestions(background:true) }
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
                        self.nextRecommendations = .distantPast
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var model: Model!
    var item: NSStatusItem!
    var window: NSWindow!
    var monthlyRecap: MonthlyRecapWindow?
    var menuSongTimer:Timer?
    var musicPlaybackObservers:[NSObjectProtocol]=[]
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
            model.openMonthlyRecap={ [weak self] in self?.showMonthlyRecap() }
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:680),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title="AM Track";window.minSize=NSSize(width:888,height:490);window.isReleasedWhenClosed=false
            let content=NSHostingView(rootView:AppContentView(model:model))
            // AppKit owns window sizing; flexible SwiftUI content must not enlarge it.
            content.sizingOptions=[]
            window.contentView=content;window.center()
            createAppMenu();updateMenu();showHistory()
            model.refreshMenuSong()
            // Playback notifications dispatch a prepared next song promptly; polling is a fallback.
            for name in ["com.apple.Music.playerInfo","com.apple.iTunes.playerInfo"] {
                musicPlaybackObservers.append(DistributedNotificationCenter.default().addObserver(forName:Notification.Name(name),object:nil,queue:.main) { [weak self] _ in
                    guard let self else { return }
                    DispatchQueue.main.async { self.model?.refreshMenuSong(notification:true) }
                })
            }
            model.refreshLibraryDetails()
            menuSongTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
                guard let delegate=self else { return }
                DispatchQueue.main.async {
                    delegate.model.refreshLibraryDetails()
                    delegate.model?.refreshMenuSong()
                }
            }
            if model.collectionEnabled && (arguments.contains("--record") || model.resumeRecordingOnLaunch) { model.start() }

        } catch {
            let alert=NSAlert();alert.messageText="AM Track could not open your history";alert.informativeText=error.localizedDescription;alert.runModal();NSApp.terminate(nil)
        }
    }
    func createAppMenu() {
        let menu=NSMenu(),root=NSMenuItem(),app=NSMenu()
        menu.addItem(root);root.submenu=app
        let recapItem=app.addItem(withTitle:"Monthly recap",action:#selector(showMonthlyRecap),keyEquivalent:"m")
        recapItem.target=self;recapItem.keyEquivalentModifierMask=[.command,.shift]
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
        menu.minimumWidth=Interface.menuWidth
        @discardableResult func add(_ title:String,_ action:Selector?=nil,_ key:String="",symbol:String?=nil) -> NSMenuItem {
            let entry=menu.addItem(withTitle:title,action:action,keyEquivalent:key)
            entry.target=self;entry.isEnabled=action != nil
            let font=menu.font ?? NSFont.menuFont(ofSize:0)
            let fitted=menuFittedText(title,font:font,width:Interface.menuTextWidth)
            entry.attributedTitle=NSAttributedString(string:fitted,attributes:[.font:font])
            if fitted != title { entry.toolTip=title }
            if let symbol {
                entry.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
                entry.image?.isTemplate=true
            }
            return entry
        }
        let heading=NSMenuItem()
        let headingView=MenuHeadingHostingView(rootView:MenuHeading(sample:model.menuSample,recording:model.recording))
        headingView.frame=NSRect(origin:.zero,size:headingView.fittingSize)
        heading.view=headingView;menu.addItem(heading)
        if !model.error.isEmpty {
            let entry=add(model.error)
            entry.toolTip=model.error
        }
        if !model.playbackError.isEmpty || !model.playbackMessage.isEmpty {
            let message=model.playbackError.isEmpty ? model.playbackMessage : model.playbackError
            let entry=add(message)
            entry.toolTip=message
        }
        if let confirmation=model.feedbackConfirmation {
            let receipt=add(confirmation.message,symbol:confirmation.symbol)
            receipt.toolTip=confirmation.message
            add("Undo feedback",#selector(undoFeedback),symbol:"arrow.uturn.backward")
        }
        menu.addItem(.separator())
        let nextEntry=add(model.playbackTrackID == nil ? "Next for you" : "Updating Music…",#selector(nextForYou),symbol:"text.line.first.and.arrowtriangle.forward")
        nextEntry.isEnabled=model.playbackTrackID == nil
        nextEntry.toolTip="Queue one recommended song without interrupting playback, then keep the queue going."
        if model.automaticQueue.enabled { add("Stop auto queue",#selector(stopAutomaticQueue),symbol:"stop.circle") }
        if let current=model.menuSample,current.musicPersistentID != nil {
            let state=model.feedback(for:current)
            let like=add("Like current song",#selector(likeCurrent(_:)),symbol:"heart");like.representedObject=current
            let less=add(state.less ? "Remove dislike" : "Less like this",#selector(lessLikeCurrent(_:)),symbol:state.less ? "hand.thumbsdown.fill" : "hand.thumbsdown");less.representedObject=current
            less.state=state.less ? .on : .off
        }
        menu.addItem(.separator())
        if #available(macOS 14.0, *) {
            menu.addItem(NSMenuItem.sectionHeader(title:"For you"))
        } else {
            add("For you")
        }
        if model.suggestions.isEmpty { add(model.libraryDetailsBusy ? "Updating your library…" : "No recommendations yet") }
        if !model.suggestions.isEmpty {
            let recommendations=NSMenuItem()
            recommendations.view=MenuRecommendationsView(songs:model.suggestions,feedback:model.songFeedback,playbackBusy:model.playbackTrackID != nil) { [weak self, weak menu] song in
                menu?.cancelTracking()
                self?.model.play(song)
            }
            menu.addItem(recommendations)
        }
        menu.addItem(.separator())
        add("Monthly recap",#selector(showMonthlyRecap),symbol:"chart.bar.xaxis")
        add("Show app window",#selector(showHistory),"0",symbol:"macwindow")
        add(model.recording ? "Stop recording" : "Start recording",#selector(toggle),symbol:model.recording ? "pause.circle" : "record.circle")
        menu.addItem(.separator())
        add("Quit AM Track",#selector(quit),"q")
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
    @objc func lessLikeCurrent(_ sender:NSMenuItem) { if let current=sender.representedObject as? Sample { model.rateCurrent(current,model.feedback(for:current).less ? "reset" : "less") } }
    @objc func undoFeedback() { model.undoFeedback() }
    @objc func nextForYou() { model.nextForYou() }
    @objc func stopAutomaticQueue() { model.stopAutomaticQueue() }
    @objc func showMonthlyRecap() {
        if monthlyRecap == nil { monthlyRecap = MonthlyRecapWindow(model: model) }
        monthlyRecap?.show()
    }
    @objc func showHistory() { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    @objc func toggle() { model.recording ? model.stop() : model.start() }
    @objc func showSuggestions() { model.selectedTab=4;showHistory() }
    @objc func checkHistory() { model.checkHistory() }
    @objc func chooseHistory() { model.chooseHistory() }
    @objc func openFolder() { NSWorkspace.shared.open(model.archive.folder) }
    @objc func quit() { model.libraryDetailsControl.cancel();model.menuSongControl.cancel();model.playbackControl.cancel();model.playbackSelectionControl.cancel();model.automaticPreparationControl.cancel();model.stop(remember:false);NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) { musicPlaybackObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) };menuSongTimer?.invalidate();model?.libraryDetailsControl.cancel();model?.menuSongControl.cancel();model?.playbackControl.cancel();model?.playbackSelectionControl.cancel();model?.automaticPreparationControl.cancel();model?.stop(remember:false) }
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
        if let index=CommandLine.arguments.firstIndex(of:"--design-preview"),CommandLine.arguments.count > index+1 {
            let app=NSApplication.shared
            app.setActivationPolicy(.accessory)
            let preview=DesignPreview(output:URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true),keepOpen:CommandLine.arguments.contains("--keep-open"))
            app.delegate=preview;app.run()
            withExtendedLifetime(preview) {}
        } else if CommandLine.arguments.contains("--self-test") {
            do { try menuLayoutTests();try onboardingTests();try selfTest();try historyTests();try manualHistoryTests();try unifiedHistoryTests();try monthlyRankingTests();try playbackTests();try forYouRefreshTests();try musicQueueTests();try automaticQueueTests();try oneAheadTests();try cachedReserveTests();try cachedAlbumTests();try recommendationTests();try recommendationRotationTests();try recommendationMigrationTests() } catch { fputs("Self-test failed: \(error)\n",stderr);exit(1) }
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
