import Foundation
import SQLite3
import CryptoKit
import Darwin

func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
func parsedDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    if let date=isoFormatter.date(from:text) { return date }
    let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
    return f.date(from:text)
}
func normalized(_ text: String) -> String {
    text.folding(options:[.caseInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX")).trimmingCharacters(in:.whitespacesAndNewlines)
}
func metadataKey(_ title:String,_ artist:String,_ album:String) -> String {
    digest(Data([title,artist,album].map(normalized).joined(separator:"\u{0}").utf8))
}

final class ArchiveLease {
    let fd: Int32
    init(_ folder:URL) throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        fd=Darwin.open(folder.appendingPathComponent(".recorder.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd >= 0 else { throw AppError(message:"Cannot lock the history folder.") }
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else {
            Darwin.close(fd)
            throw AppError(message:"Another AM Track or recorder is using this folder. Quit it before opening this copy.")
        }
    }
    deinit { flock(fd,LOCK_UN); Darwin.close(fd) }
}

// A data-only binary plist reader. It does not load archived Objective-C classes.
// Foundation's XML reader handles the outer file; this reads UID references in modobj.
private struct PlistUID { let index:Int }
private final class BinaryPlist {
    let bytes:[UInt8]; let offsets:[Int]; let refSize:Int; let root:Int; let tableStart:Int
    var cache:[Int:Any]=[:]; var visiting=Set<Int>()
    init(_ data:Data) throws {
        let buffer=Array(data);bytes=buffer
        guard bytes.count>=40, String(bytes:bytes.prefix(8),encoding:.ascii)=="bplist00" else { throw AppError(message:"Unrecognized embedded history format.") }
        let trailer=bytes.count-32, offsetSize=Int(bytes[trailer+6])
        refSize=Int(bytes[trailer+7])
        func read(_ start:Int,_ n:Int) throws -> Int {
            guard n>0,n<=8,start>=0,start+n<=buffer.count else { throw AppError(message:"Invalid property-list integer.") }
            var value:UInt64=0
            for byte in buffer[start..<start+n] { value=(value<<8)|UInt64(byte) }
            guard value<=UInt64(Int.max) else { throw AppError(message:"History value is too large.") }
            return Int(value)
        }
        let count=try read(trailer+8,8)
        root=try read(trailer+16,8); tableStart=try read(trailer+24,8)
        guard count>0,count<=100_000,root<count,refSize>0,refSize<=8,offsetSize>0,offsetSize<=8,
              tableStart>=8,tableStart<=trailer,count<=(trailer-tableStart)/offsetSize else { throw AppError(message:"Invalid embedded history structure.") }
        var positions:[Int]=[]
        for i in 0..<count {
            let p=try read(tableStart+i*offsetSize,offsetSize)
            guard p>=8,p<tableStart else { throw AppError(message:"History object is out of bounds.") }
            positions.append(p)
        }
        offsets=positions
    }
    func integer(_ at:Int,_ size:Int) throws -> Int {
        guard size>0,size<=8,at>=8,at<=tableStart-size else { throw AppError(message:"Truncated embedded history.") }
        var n:UInt64=0; for b in bytes[at..<at+size] { n=(n<<8)|UInt64(b) }
        guard n<=UInt64(Int.max) else { throw AppError(message:"Unsupported history integer.") }
        return Int(n)
    }
    func object(_ index:Int,_ depth:Int=0) throws -> Any {
        if let value=cache[index] { return value }
        guard depth<80,index>=0,index<offsets.count,!visiting.contains(index) else { throw AppError(message:"Invalid history object reference.") }
        visiting.insert(index); defer { visiting.remove(index) }
        let at=offsets[index], marker=bytes[at], kind=marker>>4, info=Int(marker&15)
        var start=at+1, length=info
        if [4,5,6,10,13].contains(Int(kind)) && info==15 {
            guard start<tableStart,bytes[start]>>4==1,bytes[start]&15<=3 else { throw AppError(message:"Invalid history length.") }
            let size=1<<Int(bytes[start]&15)
            length=try integer(start+1,size); start += 1+size
        }
        func range(_ count:Int) throws -> Range<Int> {
            guard count>=0,start<=tableStart,count<=tableStart-start else { throw AppError(message:"Truncated history payload.") }
            return start..<start+count
        }
        let value:Any
        switch kind {
        case 0: value=info==9 ? true : info==8 ? false : NSNull() as Any
        case 1:
            guard info<=3 else { throw AppError(message:"Unsupported history number.") }
            value=try integer(start,1<<info)
        case 2,3:
            let size=kind==3 ? 8 : 1<<info
            guard size==4 || size==8 else { throw AppError(message:"Invalid history real.") }
            let r=try range(size); var bits:UInt64=0
            for b in bytes[r] { bits=(bits<<8)|UInt64(b) }
            let n=size==4 ? Double(Float(bitPattern:UInt32(bits))) : Double(bitPattern:bits)
            value=kind==3 ? Date(timeIntervalSinceReferenceDate:n) as Any : n as Any
        case 4: value=Data(bytes[try range(length)])
        case 5,6:
            guard length<=tableStart/(kind==6 ? 2 : 1) else { throw AppError(message:"History string is too large.") }
            let data=Data(bytes[try range(length*(kind==6 ? 2 : 1))])
            guard let s=String(data:data,encoding:kind==6 ? .utf16BigEndian : .ascii) else { throw AppError(message:"Invalid history text.") }
            value=s
        case 8: value=PlistUID(index:try integer(start,info+1))
        case 10,13:
            guard length<=100_000,length<=((tableStart-start)/refSize)/(kind==13 ? 2 : 1) else { throw AppError(message:"History container is too large.") }
            var first:[Any]=[]
            for i in 0..<length { first.append(try object(integer(start+i*refSize,refSize),depth+1)) }
            if kind==10 { value=first }
            else {
                var dict:[String:Any]=[:]
                for i in 0..<length {
                    guard let key=first[i] as? String,dict[key]==nil else { throw AppError(message:"Invalid history dictionary.") }
                    dict[key]=try object(integer(start+(length+i)*refSize,refSize),depth+1)
                }
                value=dict
            }
        default: throw AppError(message:"Unsupported embedded history object type \(kind).")
        }
        cache[index]=value; return value
    }
}

private final class KeyedHistory {
    let objects:[Any]; let top:[String:Any]
    init(_ data:Data) throws {
        let p=try BinaryPlist(data)
        guard let root=try p.object(p.root) as? [String:Any],root["$archiver"] as? String=="NSKeyedArchiver",
              let objects=root["$objects"] as? [Any], let top=root["$top"] as? [String:Any] else { throw AppError(message:"Unsupported archived history model.") }
        self.objects=objects;self.top=top
    }
    func ref(_ value:Any?) throws -> Any? {
        guard let uid=value as? PlistUID else { return value }
        guard uid.index>=0,uid.index<objects.count else { throw AppError(message:"History UID is out of range.") }
        return uid.index==0 ? nil : objects[uid.index]
    }
    func dict(_ value:Any?) throws -> [String:Any] { try ref(value) as? [String:Any] ?? [:] }
    func array(_ value:Any?) throws -> [Any] { try dict(value)["NS.objects"] as? [Any] ?? [] }
    func props(_ value:Any?) throws -> [String:Any] {
        let obj=try dict(value), store=try dict(obj["storage"] ?? obj)
        guard store["NS.values"] != nil else { return [:] }
        let keys=try array(store["NS.keys"]),values=try array(store["NS.values"])
        guard keys.count==values.count else { throw AppError(message:"History metadata keys do not match values.") }
        var result:[String:Any]=[:]
        for (k,v) in zip(keys,values) {
            guard let key=try ref(k) as? String else { throw AppError(message:"Invalid history property key.") }
            result[key]=try ref(v)
        }
        return result
    }
    func song() throws -> [String:Any] {
        let root=try props(top["ModelObject"])
        guard let song=root["MPModelRelationshipGenericSong"] else { throw AppError(message:"History model has no song.") }
        return try dict(song)
    }
}

struct ImportedSong {
    var title:String; var artist=""; var album=""; var genre=""; var catalogID=""; var persistentID=""; var duration:Double=0;var context=""
}
struct HistorySnapshot {
    let hash:String; let songs:[ImportedSong]; let source:URL; let modified:String; let captured:Date
    static func read(_ source:URL) throws -> HistorySnapshot {
        let access=source.startAccessingSecurityScopedResource();defer { if access { source.stopAccessingSecurityScopedResource() } }
        let before=try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.isRegularFileKey])
        guard before.isRegularFile==true,let size=before.fileSize,size<=64*1024*1024 else { throw AppError(message:"Choose a History.dat file smaller than 64 MB.") }
        let data=try Data(contentsOf:source)
        let after=try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        guard before.fileSize==after.fileSize,before.contentModificationDate==after.contentModificationDate else { throw AppError(message:"Music is updating History.dat. The next check will retry.") }
        guard let root=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any],
              number(root["version"])==1,let container=root["items"] as? [String:Any],let entries=container["iar"] as? [[String:Any]],entries.count<=10_000 else { throw AppError(message:"Unsupported History.dat format; your saved history has been kept.") }
        var songs:[ImportedSong]=[]
        for entry in entries {
            guard let pm=entry["pm"] as? [String:Any],let title=pm["name"] as? String,!title.isEmpty else { throw AppError(message:"A history entry has no song title. Import cancelled.") }
            var song=ImportedSong(title:title)
            if let desc=pm["contentDesc"] as? [String:Any],let ids=desc["identifiers"] as? [String:Any] {
                song.catalogID=ids["storeAdamID"] as? String ?? ""
                if let text=ids["libraryItemID"] as? String,let range=text.range(of:"-PID:0x"),let end=text[range.upperBound...].firstIndex(of:"-") {
                    song.persistentID=String(text[range.upperBound..<end]).uppercased()
                    if song.persistentID.count<16 { song.persistentID=String(repeating:"0",count:16-song.persistentID.count)+song.persistentID }
                }
            }
            if let data=pm["modobj"] as? Data {
                let archive=try KeyedHistory(data),model=try archive.song(),props=try archive.props(model)
                guard props["MPModelPropertySongTitle"] as? String==title else { throw AppError(message:"History metadata title mismatch. Import cancelled.") }
                let ids=try archive.dict(model["identifiers"])
                let store=number(ids["MPIdentifierSetStoreAdamID"]),subscription=number(ids["MPIdentifierSetStoreSubscriptionAdamID"])
                let id=store>0 ? store : subscription
                if id>0 { song.catalogID=String(format:"%.0f",id) }
                song.artist=try archive.props(props["MPModelRelationshipSongArtist"])["MPModelPropertyPersonName"] as? String ?? ""
                song.album=try archive.props(props["MPModelRelationshipSongAlbum"])["MPModelPropertyAlbumTitle"] as? String ?? ""
                song.genre=try archive.props(props["MPModelRelationshipSongGenre"])["MPModelPropertyGenreName"] as? String ?? ""
                song.duration=number(props["MPModelPropertySongDuration"])
                var contexts:[String]=[]
                for value in archive.top.values {
                    let p=try archive.props(value)
                    for name in ["MPModelRelationshipGenericPlaylist","MPModelRelationshipGenericRadioStation"] {
                        let q=try archive.props(p[name])
                        if let s=q["MPModelPropertyPlaylistName"] as? String ?? q["MPModelPropertyRadioStationName"] as? String,!s.isEmpty { contexts.append(s) }
                    }
                }
                song.context=contexts.joined(separator:" | ")
            }
            guard !song.catalogID.isEmpty || !song.persistentID.isEmpty else { throw AppError(message:"History song has no stable identifier. Import cancelled.") }
            songs.append(song)
        }
        return HistorySnapshot(hash:digest(data),songs:songs,source:source,modified:stamp(after.contentModificationDate ?? Date()),captured:Date())
    }
}

extension Archive {
    func transaction<T>(_ body:() throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result=try body();try exec("COMMIT");return result }
        catch { try? exec("ROLLBACK");throw error }
    }
    func backup(to url:URL) throws {
        var target:OpaquePointer?
        guard sqlite3_open(url.path,&target)==SQLITE_OK else { sqlite3_close(target);throw AppError(message:"Could not create the database backup.") }
        defer { sqlite3_close(target) }
        guard let copy=sqlite3_backup_init(target,"main",handle,"main") else { throw AppError(message:"Could not start the database backup.") }
        let result=sqlite3_backup_step(copy,-1),finished=sqlite3_backup_finish(copy)
        guard result==SQLITE_DONE,finished==SQLITE_OK else { throw AppError(message:"Database backup failed. Upgrade cancelled.") }
        chmod(url.path,0o600)
    }
    func migrate() throws {
        let version=Int(try rows("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
        guard version<=4 else { throw AppError(message:"This archive needs a newer version of AM Track.") }
        guard version<4 else { return }
        guard try rows("PRAGMA integrity_check").first?["integrity_check"]=="ok" else { throw AppError(message:"Database integrity check failed. Upgrade cancelled.") }
        let backups=folder.appendingPathComponent("backups",isDirectory:true)
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:true)
        let backupURL=backups.appendingPathComponent("history-before-v4-\(UUID().uuidString).sqlite3")
        try backup(to:backupURL)
        if version<2 {
        try transaction {
            try exec("ALTER TABLE sessions ADD COLUMN last_listening_at TEXT")
            try exec("CREATE TABLE music_tracks (id TEXT PRIMARY KEY,title TEXT NOT NULL,artist TEXT NOT NULL DEFAULT '',album TEXT NOT NULL DEFAULT '',genre TEXT NOT NULL DEFAULT '',duration REAL NOT NULL DEFAULT 0,metadata_key TEXT NOT NULL)")
            try exec("CREATE INDEX music_metadata ON music_tracks(metadata_key)")
            try exec("CREATE TABLE track_aliases (kind TEXT NOT NULL,value TEXT NOT NULL,track_id TEXT NOT NULL REFERENCES music_tracks(id),PRIMARY KEY(kind,value))")
            try exec("CREATE TABLE recording_tracks (session_id INTEGER PRIMARY KEY REFERENCES sessions(id),track_id TEXT NOT NULL REFERENCES music_tracks(id))")
            try exec("CREATE TABLE history_snapshots (id INTEGER PRIMARY KEY,sha256 TEXT UNIQUE NOT NULL,source_path TEXT NOT NULL,captured_at TEXT NOT NULL,modified_at TEXT NOT NULL,entry_count INTEGER NOT NULL,state TEXT NOT NULL,note TEXT NOT NULL)")
            try exec("CREATE TABLE history_occurrences (id INTEGER PRIMARY KEY,track_id TEXT NOT NULL REFERENCES music_tracks(id),first_snapshot_id INTEGER NOT NULL REFERENCES history_snapshots(id),first_ordinal INTEGER NOT NULL,window_start TEXT,window_end TEXT,UNIQUE(first_snapshot_id,first_ordinal))")
            try exec("CREATE TABLE history_items (snapshot_id INTEGER NOT NULL REFERENCES history_snapshots(id),ordinal INTEGER NOT NULL,track_id TEXT NOT NULL REFERENCES music_tracks(id),occurrence_id INTEGER REFERENCES history_occurrences(id),context TEXT NOT NULL DEFAULT '',PRIMARY KEY(snapshot_id,ordinal))")
            try exec("CREATE TABLE history_matches (occurrence_id INTEGER PRIMARY KEY REFERENCES history_occurrences(id),session_id INTEGER UNIQUE NOT NULL REFERENCES sessions(id),method TEXT NOT NULL)")
            try exec("CREATE TABLE history_checks (id INTEGER PRIMARY KEY,checked_at TEXT NOT NULL,source_path TEXT NOT NULL,state TEXT NOT NULL,detail TEXT NOT NULL)")
            try exec("CREATE TABLE track_feedback (id INTEGER PRIMARY KEY,track_id TEXT NOT NULL REFERENCES music_tracks(id),kind TEXT NOT NULL CHECK(kind IN ('like','less','later','reset')),created_at TEXT NOT NULL)")
            try exec("CREATE TABLE recommendation_batches (id INTEGER PRIMARY KEY,created_at TEXT NOT NULL,track_ids TEXT NOT NULL)")
            try meta("upgrade_backup",backupURL.path)
            try exec("PRAGMA user_version=2")
        }
        }
        if version<3 {
            try createUnifiedSchema()
            try meta("unified_upgrade_backup",backupURL.path)
        }
        try transaction {
            try exec("""
                CREATE TABLE track_album_metadata (
                    track_id TEXT PRIMARY KEY REFERENCES music_tracks(id),album_artist TEXT NOT NULL,
                    album_title TEXT NOT NULL,disc_number INTEGER NOT NULL,disc_count INTEGER NOT NULL,
                    track_number INTEGER NOT NULL,track_count INTEGER NOT NULL,updated_at TEXT NOT NULL)
                """)
            // A single journal makes Undo work across song, album and listening-mode feedback.
            try exec("""
                CREATE TABLE recommendation_feedback (
                    id INTEGER PRIMARY KEY,target_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('like','less','later','reset','mode_auto','mode_album','mode_tracks')),
                    created_at TEXT NOT NULL)
                """)
            try exec("CREATE INDEX recommendation_feedback_target ON recommendation_feedback(target_id,id)")
            try exec("INSERT INTO recommendation_feedback(id,target_id,kind,created_at) SELECT id,track_id,kind,created_at FROM track_feedback ORDER BY id")
            try exec("PRAGMA user_version=4")
            try meta("recommendations_upgrade_backup",backupURL.path)
        }
    }
    func value(_ key:String) throws -> String { try rows("SELECT value FROM metadata WHERE key=?",[key]).first?["value"] ?? "" }
    func resolve(_ input:ImportedSong) throws -> String {
        var song=input
        song.persistentID=song.persistentID.uppercased()
        if !song.persistentID.isEmpty,let local=try rows("SELECT * FROM library_tracks WHERE upper(persistent_id)=?",[song.persistentID]).first {
            if song.artist.isEmpty { song.artist=local["artist"] ?? "" }
            if song.album.isEmpty { song.album=local["album"] ?? "" }
        }
        var aliases:[(String,String)]=[]
        if !song.persistentID.isEmpty { aliases.append(("persistent",song.persistentID)) }
        if !song.catalogID.isEmpty { aliases.append(("catalog",song.catalogID)) }
        let existing=try Set(aliases.compactMap { kind,value in try rows("SELECT track_id FROM track_aliases WHERE kind=? AND value=?",[kind,value]).first?["track_id"] })
        guard existing.count<=1 else { throw AppError(message:"Conflicting song identifiers found. History has been kept for review.") }
        let key=metadataKey(song.title,song.artist,song.album)
        var chosen=existing.first
        if chosen==nil && !song.artist.isEmpty && !song.album.isEmpty {
            let candidates=try rows("SELECT id FROM music_tracks WHERE metadata_key=?",[key])
            if candidates.count==1,let candidate=candidates.first?["id"] {
                // Do not merge two catalog releases or two library records merely by their names.
                let conflicts=try aliases.contains { kind,value in
                    !(try rows("SELECT value FROM track_aliases WHERE track_id=? AND kind=? AND value<>?",[candidate,kind,value])).isEmpty
                }
                if !conflicts { chosen=candidate }
            }
        }
        let id=chosen ?? UUID().uuidString
        if chosen==nil {
            try exec("INSERT INTO music_tracks VALUES (?,?,?,?,?,?,?)",[id,song.title,song.artist,song.album,song.genre,song.duration,key])
        } else {
            try exec("UPDATE music_tracks SET artist=CASE WHEN artist='' THEN ? ELSE artist END,album=CASE WHEN album='' THEN ? ELSE album END,genre=CASE WHEN genre='' THEN ? ELSE genre END,duration=CASE WHEN duration=0 THEN ? ELSE duration END WHERE id=?",[song.artist,song.album,song.genre,song.duration,id])
            if let row=try rows("SELECT * FROM music_tracks WHERE id=?",[id]).first { try exec("UPDATE music_tracks SET metadata_key=? WHERE id=?",[metadataKey(row["title"] ?? "",row["artist"] ?? "",row["album"] ?? ""),id]) }
        }
        for (kind,value) in aliases { try exec("INSERT OR IGNORE INTO track_aliases VALUES (?,?,?)",[kind,value,id]) }
        return id
    }
    func syncRecordingsAndLibrary(includeLibrary:Bool=true) throws {
        try transaction {
            for row in try includeLibrary ? rows("SELECT * FROM library_tracks") : [] {
                var song=ImportedSong(title:row["title"] ?? "")
                song.artist=row["artist"] ?? "";song.album=row["album"] ?? "";song.persistentID=row["persistent_id"] ?? ""
                _=try resolve(song)
            }
            for row in try rows("SELECT s.* FROM sessions s LEFT JOIN recording_tracks r ON r.session_id=s.id WHERE r.session_id IS NULL ORDER BY s.id") {
                var song=ImportedSong(title:row["title"] ?? "")
                song.artist=row["artist"] ?? "";song.album=row["album"] ?? "";song.persistentID=row["persistent_id"] ?? "";song.duration=Double(row["duration"] ?? "0") ?? 0
                let id=try resolve(song)
                try exec("INSERT INTO recording_tracks VALUES (?,?)",[Int(row["id"]!)!,id])
            }
        }
        try syncUnifiedHistory()
    }
    func logHistory(_ state:String,_ detail:String,_ source:String,at date:Date=Date()) throws {
        try exec("INSERT INTO history_checks(checked_at,source_path,state,detail) VALUES (?,?,?,?)",[stamp(date),source,state,detail])
        try meta("history_last_check",stamp(date));try meta("history_state",state);try meta("history_detail",detail)
    }
    @discardableResult func ingest(_ snapshot:HistorySnapshot) throws -> String {
        try transaction {
            let lastObserved=try value("history_observed_at"),lastSource=try value("history_observed_source")
            try meta("history_observed_at",stamp(snapshot.captured));try meta("history_observed_source",snapshot.source.path)
            if let known=try rows("SELECT * FROM history_snapshots WHERE sha256=?",[snapshot.hash]).first {
                try meta("history_current_snapshot",known["id"]!)
                let note="Previously imported snapshot: \(snapshot.songs.count) entries; no additional plays established. " + (known["note"] ?? "")
                try logHistory(known["state"] ?? "unchanged",note,snapshot.source.path,at:snapshot.captured)
                return note
            }
            let previous=try rows("SELECT * FROM history_snapshots WHERE id=CAST((SELECT value FROM metadata WHERE key='history_current_snapshot') AS INTEGER)").first
            let oldItems=try previous.map { try rows("SELECT track_id,occurrence_id FROM history_items WHERE snapshot_id=? ORDER BY ordinal",[Int($0["id"]!)!]) } ?? []
            let ids=try snapshot.songs.map(resolve),old=oldItems.compactMap { $0["track_id"] }
            var overlap=0,state="baseline",note="Imported baseline; dates and completion are unknown."
            let sameSource=lastSource==snapshot.source.path
            if previous != nil {
                if sameSource && old==ids {
                    overlap=ids.count;state="metadata_only";note="Same sequence; metadata changed. No plays added."
                } else if sameSource && !old.isEmpty && !ids.isEmpty {
                    // Single-song/pattern overlaps cannot establish how many replays occurred.
                    let minimum=min(3,min(old.count,ids.count))
                    let matches=(minimum...min(old.count,ids.count)).filter { Array(old.suffix($0))==Array(ids.prefix($0)) }
                    if matches.count==1,let count=matches.first,count>=3,
                       Set(old.suffix(count)).count>=2 {
                        overlap=count;state="overlap";note="Sequence overlap: \(count) retained, \(ids.count-count) new history entries."
                    } else { state="review";note="History was cleared, replaced, or overlaps ambiguously. All entries saved; additional play counts are unresolved." }
                } else if ids.isEmpty {
                    state="cleared";note="Music history is empty. Earlier archived entries have been kept."
                } else { state="review";note="History source changed or has no reliable overlap. Snapshot saved without assuming extra plays." }
            }
            try exec("INSERT INTO history_snapshots(sha256,source_path,captured_at,modified_at,entry_count,state,note) VALUES (?,?,?,?,?,?,?)",[snapshot.hash,snapshot.source.path,stamp(snapshot.captured),snapshot.modified,ids.count,state,note])
            let snapshotID=sqlite3_last_insert_rowid(handle)
            let previousDate=lastObserved.isEmpty ? nil : lastObserved
            let canBound=state=="overlap" && isLiveHistory(snapshot.source)
                && parsedDate(previousDate).map { snapshot.captured.timeIntervalSince($0)>=0 && snapshot.captured.timeIntervalSince($0)<=120 } == true
            for (i,id) in ids.enumerated() {
                var occurrence:Int64?
                if i<overlap { occurrence=Int64(oldItems[oldItems.count-overlap+i]["occurrence_id"] ?? "") }
                else if state=="baseline" || state=="overlap" {
                    try exec("INSERT INTO history_occurrences(track_id,first_snapshot_id,first_ordinal,window_start,window_end) VALUES (?,?,?,?,?)",[id,snapshotID,i,canBound ? previousDate : nil,canBound ? stamp(snapshot.captured) : nil])
                    occurrence=sqlite3_last_insert_rowid(handle)
                }
                try exec("INSERT INTO history_items VALUES (?,?,?,?,?)",[snapshotID,i,id,occurrence,snapshot.songs[i].context])
            }
            try meta("history_current_snapshot",String(snapshotID));try logHistory(state,note,snapshot.source.path,at:snapshot.captured)
            return note
        }
    }
    func reconcile() throws {
        // A likely match is only allowed for a newly observed live-file change, never
        // for the undated imported baseline. Preserve the method as uncertainty.
        try transaction {
            let occurrences=try rows("SELECT h.* FROM history_occurrences h LEFT JOIN history_matches m ON m.occurrence_id=h.id WHERE m.occurrence_id IS NULL AND h.window_start IS NOT NULL")
            var candidates:[String:[String]]=[:]
            for h in occurrences {
                let ids=try rows("SELECT s.id FROM sessions s JOIN recording_tracks r ON r.session_id=s.id LEFT JOIN history_matches m ON m.session_id=s.id WHERE r.track_id=? AND m.session_id IS NULL AND datetime(s.first_observed_at)<=datetime(?) AND datetime(COALESCE(s.ended_at,s.last_observed_at))>=datetime(?)",[h["track_id"],h["window_end"],h["window_start"]]).compactMap {$0["id"]}
                candidates[h["id"]!]=ids
            }
            let usage=Dictionary(grouping:candidates.values.flatMap{$0},by:{$0}).mapValues{$0.count}
            for (id,sessions) in candidates where sessions.count==1 && usage[sessions[0]]==1 {
                try exec("INSERT OR IGNORE INTO history_matches VALUES (?,?,?)",[Int(id)!,Int(sessions[0])!,"likely: same track within live check window; not an exact playback timestamp"])
            }
        }
    }
    func audit(full:Bool=false) throws -> [String:Any] {
        let pragma=full ? "integrity_check" : "quick_check"
        let integrity=try rows("PRAGMA \(pragma)").map{$0[pragma] ?? "unknown"}
        let foreign=try rows("PRAGMA foreign_key_check")
        let missing=try rows("SELECT s.id FROM sessions s LEFT JOIN recording_tracks r ON r.session_id=s.id WHERE r.session_id IS NULL")
        let mismatches=try rows("SELECT p.id FROM history_snapshots p WHERE p.entry_count<>(SELECT COUNT(*) FROM history_items i WHERE i.snapshot_id=p.id)")
        let invalid=try rows("SELECT id FROM sessions WHERE observed_listening_seconds<0 OR datetime(last_observed_at)<datetime(first_observed_at)")
        let metadataErrors=try rows("SELECT * FROM music_tracks").filter { metadataKey($0["title"] ?? "",$0["artist"] ?? "",$0["album"] ?? "") != $0["metadata_key"] }
        let unified=try auditUnifiedHistory()
        let good=unified["unified_ok"] as? Bool==true && integrity==["ok"] && foreign.isEmpty && missing.isEmpty && mismatches.isEmpty && invalid.isEmpty && metadataErrors.isEmpty
        var report:[String:Any]=["checked_at":stamp(),"database_ok":good,"sqlite":integrity,"foreign_key_errors":foreign.count,"unmapped_recordings":missing.count,"snapshot_count_errors":mismatches.count,"invalid_sessions":invalid.count,"metadata_key_errors":metadataErrors.count,
            "recorded_sessions":try rows("SELECT COUNT(*) n FROM sessions").first?["n"] ?? "0",
            "history_occurrences":try rows("SELECT COUNT(*) n FROM history_occurrences").first?["n"] ?? "0",
            "history_observations":try rows("SELECT COUNT(*) n FROM history_items").first?["n"] ?? "0",
            "unresolved_history_entries":try rows("SELECT COUNT(*) n FROM history_items WHERE occurrence_id IS NULL").first?["n"] ?? "0",
            "likely_matches":try rows("SELECT COUNT(*) n FROM history_matches").first?["n"] ?? "0",
            "coverage":"All successfully imported snapshots and observed sessions are preserved. Undated source overlap, missed checks, sleep, and time before recording can leave unknown plays; library totals are not reconstructed events."]
        report.merge(unified) { _,new in new }
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("database-health.json"),options:.atomic)
        try meta("database_last_audit",stamp());try meta("database_ok",good ? "yes" : "no")
        return report
    }

}

func isLiveHistory(_ url:URL) -> Bool {
    url.lastPathComponent=="History.dat" && url.deletingLastPathComponent().lastPathComponent=="Preferences"
        && url.deletingLastPathComponent().deletingLastPathComponent().pathExtension=="musiclibrary"
}
