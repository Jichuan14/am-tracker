import Foundation

@MainActor func manualHistoryTests() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-manual-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let fixture:[String:Any] = ["version":1,"items":["iar":[["pm":["name":"Manual song","contentDesc":["identifiers":["storeAdamID":"1234"]]]]]]]
    try PropertyListSerialization.data(fromPropertyList:fixture,format:.xml,options:0).write(to:folder.appendingPathComponent("History.dat"))
    let model=try Model(folder:folder)
    try check(!model.historyBusy,"startup must not request a History.dat read")
    try check(try model.archive.rows("SELECT * FROM history_checks").isEmpty,"startup must not create a history check")
    model.checkHistory()
    let deadline=Date().addingTimeInterval(5)
    while model.historyBusy && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    try check(!model.historyBusy,"manual history check completes")
    try check(try model.archive.rows("SELECT * FROM history_items").count==1,"explicit history check imports the supplied file")
    print("PASS: no startup History.dat read; explicit manual check still imports history.")
}

private func check(_ condition:Bool,_ message:String) throws {
    guard condition else { throw AppError(message:"Self-test: "+message) }
}

@MainActor func forYouRefreshTests() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-refresh-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let model=try Model(folder:folder),now=Date()
    let library=(1...16).map { n -> [String:Any] in
        ["persistent_id":String(format:"%016X",n),"title":"Refresh song \(n)","artist":"Artist \(n)",
         "album_artist":"Artist \(n)","album":"Album \(n)","genre":"Pop","duration":180,
         "play_count":20,"last_played":stamp(now.addingTimeInterval(-20*86400)),
         "disc_number":1,"disc_count":1,"track_number":1,"track_count":1]
    }
    try model.archive.ingestLibrary(["running":true,"tracks":library]);model.refreshSuggestions()
    let initial=model.suggestions
    let all=try model.archive.recommendations(limit:100)
    let outside=all.first { candidate in !initial.contains{$0.id==candidate.id} }!
    let pid=try model.archive.playbackIDs(for:outside.id).first!
    let current=Sample(["running":true,"state":"paused","title":outside.title,"artist":outside.artist,
        "album":outside.album,"persistent_id":pid])
    model.rateCurrent(current,"like")
    let liked=try model.archive.recommendations(limit:100)
    try check(liked.first{$0.id==outside.id}!.score>outside.score,"liking a song outside For you changes its score with recording off")
    model.rateCurrent(current,"less")
    let less=try model.archive.recommendations(limit:100)
    try check(!less.contains{$0.id==outside.id},"less-like outside For you suppresses that song")
    try check(less.contains { song in liked.first{$0.id==song.id}.map{song.score<$0.score} ?? false },"less-like outside For you also lowers scores for similar music")
    model.undoFeedback()
    try check(try model.archive.recommendationFeedback(now:Date())[outside.id]?.liked==true,"undo restores the external song's like")
    let selected=model.suggestions.first!,ids=try model.archive.playbackIDs(for:selected.id)
    let before=model.suggestions.map{$0.id}
    let ratingsBefore=try model.archive.rows("SELECT * FROM recommendation_feedback").count
    var rejected=false
    do { try model.completeForYouPlayback(selected,response:["status":"unavailable"],requestedIDs:ids) } catch { rejected=true }
    try check(rejected && model.suggestions.map{$0.id}==before,"failed playback leaves the current batch intact")
    try check(try model.archive.forYouPlaybackCooldowns().isEmpty,"failed playback creates no cooldown")
    try check(try model.archive.rows("SELECT * FROM recommendation_feedback").count==ratingsBefore,"failed playback never creates an automatic Like")
    try model.completeForYouPlayback(selected,response:["status":"playing","persistent_id":ids[0]],requestedIDs:ids)
    let automaticLike=try model.archive.rows("SELECT * FROM recommendation_feedback ORDER BY id DESC LIMIT 1").first!
    try check(try model.archive.rows("SELECT * FROM recommendation_feedback").count==ratingsBefore+1 && automaticLike["target_id"]==selected.id && automaticLike["kind"]=="like","a confirmed manual song selection automatically Likes that exact song")
    try check(!model.recording && model.suggestions.count==10 && !model.suggestions.contains{$0.id==selected.id},"confirmed playback immediately replaces the selected song with recording off")
    model.nextRecommendations = .distantPast;model.reload()
    try check(!model.suggestions.contains{$0.id==selected.id},"later reloads cannot restore a cooling selection")
    let reopened=try Archive(folder:folder)
    try check(try !reopened.recommendations(limit:100).contains{$0.id==selected.id},"selection cooldown survives reopening the archive")
    try check(try reopened.recommendations(now:now.addingTimeInterval(86405),limit:100).contains{$0.id==selected.id},"selection cooldown expires after 24 hours")
    model.undoFeedback()
    try check(try model.archive.rows("SELECT * FROM recommendation_feedback").count==ratingsBefore,"automatic Like can be undone with the existing feedback action")
    try check(try model.archive.rows("SELECT * FROM sessions").isEmpty && model.archive.unifiedRows().isEmpty,"feedback and confirmed starts do not invent listening history")
    print("PASS: off-list feedback changes ranking; confirmed playback refreshes and refills For you, failures preserve it, cooldown persists/expires, no fabricated history.")
}

@MainActor func musicQueueTests() throws {
    let a="0000000000000001",b="0000000000000002",requests:[[String:Any]]=[["ids":[a]],["ids":[b]]]
    let response:[String:Any]=["status":"resolved","tracks":[["index":0,"status":"no_catalog_id"],["index":1,"status":"resolved","persistent_id":b,"catalog_id":"1234567890"]]]
    let mapped=try resolvedQueueSongs(response,requests:requests)
    try check(mapped.count==1 && mapped[0].index==1 && mapped[0].persistentID==b,"catalog mapping skips unsupported songs while retaining exact input identity")
    for bad:[String:Any] in [
        ["status":"resolved","tracks":[["index":0,"status":"resolved","persistent_id":b,"catalog_id":"1234567890"],["index":1,"status":"not_found"]]],
        ["status":"resolved","tracks":[["index":1,"status":"not_found"],["index":0,"status":"not_found"]]]
    ] {
        var rejected=false;do { _=try resolvedQueueSongs(bad,requests:requests) } catch { rejected=true }
        try check(rejected,"wrong persistent identity or shuffled mapping indices cannot queue a different song")
    }
    try MusicQueue.confirm(["status":"accepted","catalog_id":"1234567890","return_statuses":[0]],catalogID:"1234567890")
    for bad:[String:Any] in [
        ["status":"accepted","catalog_id":"1234567890","return_statuses":[1]],
        ["status":"accepted","catalog_id":"1234567890","return_statuses":[]],
        ["status":"accepted","catalog_id":"999","return_statuses":[0]],
        ["status":"unknown"],["status":"rejected"]
    ] {
        var rejected=false;do { try MusicQueue.confirm(bad,catalogID:"1234567890") } catch { rejected=true }
        try check(rejected,"timeouts, backend rejection, incomplete acknowledgements and wrong IDs cannot report insertion success")
    }
    try check(!MusicQueue.validCatalogID("ABCDEF0123456789") && !MusicQueue.validCatalogID("1234567890\n") && MusicQueue.validCatalogID("1234567890"),"library hex IDs cannot leak into the catalog ID namespace")
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-background-batch-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let model=try Model(folder:folder);model.menuSongBusy=true
    for n in 1...16 {
        var song=ImportedSong(title:"Background \(n)");song.persistentID=String(format:"%016X",n)
        let id=try model.archive.resolve(song);try model.archive.feedback(id,"like")
    }
    model.catalogResolveOverride={ requests in
        // The leading unsupported song is skipped without losing index identity.
        requests.enumerated().dropFirst().map { index,request in
            CatalogQueueSong(index:index,persistentID:(request["ids"] as! [String])[0],catalogID:String(index+1))
        }
    }
    var appended:[String]=[]
    model.queueAppendOverride={ request in appended.append(request["catalog_id"] as! String);return 1 }
    let feedback=try model.archive.rows("SELECT * FROM recommendation_feedback").count
    model.nextForYou()
    var deadline=Date().addingTimeInterval(5)
    while model.playbackTrackID != nil && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    try check(appended==["2","3","4","5","6"] && model.playedForYouIDs.count==5 && model.automaticQueue.enabled,"five mapped songs append sequentially, skip unsupported items and start monitoring without Accessibility")
    var attempts=0
    model.queueAppendOverride={_ in attempts += 1;if attempts==3 { throw AppError(message:"Native append rejected") };return 1}
    model.nextForYou();deadline=Date().addingTimeInterval(5)
    while model.playbackTrackID != nil && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    try check(attempts==3 && model.playedForYouIDs.count==7 && !model.automaticQueue.enabled && model.playbackMessage.contains("Added 2") && model.playbackError.contains("Native append rejected"),"partial background batch cools exactly its accepted prefix and never retries ambiguous additions")
    try check(try model.archive.rows("SELECT * FROM recommendation_feedback").count==feedback && model.archive.rows("SELECT * FROM sessions").isEmpty,"background batches invent no Likes or listening history")
    print("PASS: exact library/catalog mapping, unsupported-item skips, strict backend acknowledgements and fail-closed timeouts.")
}

func playbackTests() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-playback-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let db=try Archive(folder:folder)
    var first=ImportedSong(title:"Same title");first.artist="Artist";first.persistentID="0000000000000001"
    var second=first;second.album="Other version";second.persistentID="0000000000000002"
    let selected=try db.resolve(first),other=try db.resolve(second)
    try check(selected != other,"same-titled versions keep separate identities")
    try check(try db.playbackIDs(for:selected)==[first.persistentID],"selected version resolves only its own library ID")
    try check(try db.playbackIDs(for:other)==[second.persistentID],"other version keeps its own library ID")
    let historyOnly=try db.resolve(ImportedSong(title:"History only"))
    try check(try db.playbackIDs(for:historyOnly).isEmpty,"no title-based playback fallback for unmatched history")
    try db.exec("INSERT INTO track_aliases VALUES ('persistent',?,?)",["bad-id",selected])
    try check(try db.playbackIDs(for:selected)==[first.persistentID],"invalid aliases never reach Music")
    try confirmPlayback(["status":"playing","persistent_id":first.persistentID],requestedIDs:[first.persistentID])
    for response:[String:Any] in [["status":"playing","persistent_id":second.persistentID],["status":"not_found"],["status":"unavailable"],["status":"unknown"]] {
        var rejected=false
        do { try confirmPlayback(response,requestedIDs:[first.persistentID]) } catch { rejected=true }
        try check(rejected,"unconfirmed, wrong-song and unavailable playback cannot report success")
    }
    let current=Sample(["running":true,"state":"paused","title":first.title,"artist":first.artist,"album":first.album,"persistent_id":first.persistentID])
    try db.feedbackForCurrentSong(current,"like")
    try check(try db.rows("SELECT target_id FROM recommendation_feedback ORDER BY id DESC LIMIT 1").first?["target_id"]==selected,"menu feedback targets the displayed library version")
    try db.feedback(other,"like")
    var third=ImportedSong(title:"Third");third.artist="Other artist";third.persistentID="0000000000000003"
    let thirdID=try db.resolve(third);try db.feedback(thirdID,"like")
    let next=try db.nextForYou(excluding:[other],currentPersistentID:first.persistentID)
    try check(next?.id==thirdID,"Next for you skips the current track and tracks already played this session")
    try check(try db.nextForYou(excluding:[other,thirdID],currentPersistentID:first.persistentID)==nil,"exhausted recommendations never requeue an already selected item")
    let displayed=try [db.recommendationForTrack(other)!,db.recommendationForTrack(thirdID)!]
    for _ in 0..<40 {
        let random=try db.nextForYou(from:displayed,excluding:[],currentPersistentID:first.persistentID)
        try check(displayed.contains{$0.id==random?.id},"random picks always come from the supplied visible recommendations")
    }
    try check(try db.nextForYou(from:[],excluding:[],currentPersistentID:nil)==nil,"an empty visible batch never falls back to hidden recommendations")
    try db.feedbackForCurrentSong(current,"less")
    try check(try !db.recommendations().contains{$0.id==selected},"menu less-like feedback removes the selected song from recommendations")
    try check(try db.rows("SELECT * FROM sessions").isEmpty,"menu feedback and selection never create recorder sessions")
    let withoutID=Sample(["running":true,"state":"playing","title":"Same title","artist":"Artist"])
    var refused=false
    do { try db.feedbackForCurrentSong(withoutID,"like") } catch { refused=true }
    try check(refused,"menu feedback refuses unstable metadata-only song identities")
    print("PASS: exact playback identity, same-title versions, unmatched history, invalid IDs and playback confirmation.")
    print("PASS: current-song menu feedback, next recommendation advancement, current-track exclusion and recording-independent actions.")
}

func unifiedHistoryTests() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-unified-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let db=try Archive(folder:folder),base=Date(timeIntervalSince1970:1_780_000_000)
    func record(_ name:String,_ offset:Double) throws {
        try db.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?)",[name,"Song "+name,"Artist "+name,"Album "+name,stamp(base.addingTimeInterval(offset)),stamp(base.addingTimeInterval(offset+10)),stamp(base.addingTimeInterval(offset+10)),10,100])
    }
    func snapshot(_ names:[String],_ hash:String,_ offset:Double) throws {
        let songs=names.map { name -> ImportedSong in
            var s=ImportedSong(title:"Song "+name);s.artist="Artist "+name;s.album="Album "+name;s.persistentID=name;s.catalogID="catalog-"+name;return s
        }
        try db.ingest(HistorySnapshot(hash:hash,songs:songs,source:folder.appendingPathComponent("History.dat"),modified:stamp(base.addingTimeInterval(offset)),captured:base.addingTimeInterval(offset)))
        try db.syncRecordingsAndLibrary();try db.syncUnifiedHistory(preferMusic:true)
    }
    for (i,name) in ["A","B","C","noise","D","E","F","outside"].enumerated() { try record(name,Double(i)*20) }
    try db.syncRecordingsAndLibrary()
    try check(try db.unifiedRows().count==8,"recordings enter the shared history before any dat check")
    try snapshot(["D","E","F","older","A","B","C","missed","D","E","F"],"priority",1000)
    let first=try db.unifiedRows()
    try check(first.count==12,"Music fills recording gaps and supersedes recorder noise inside covered anchors")
    try check(first.filter{$0["source"]=="Music + recording"}.count==6,"matched evidence appears once")
    try check(first.contains{$0["title"]=="Song outside"},"recording outside covered Music sequence retained")
    try check(!first.contains{$0["title"]=="Song noise"},"Music has priority within the covered sequence")
    try check(try db.rows("SELECT * FROM sessions").count==8,"superseded raw recordings remain auditable")
    try check(first.first{$0["title"]=="Song missed"}?["first_observed_at"]==nil,"no timestamps fabricated for missed listens")
    let ids=Set(first.map{$0["id"]!})
    try snapshot(["D","E","F","older","A","B","C","missed","D","E","F"],"priority",1100)
    try check(try Set(db.unifiedRows().map{$0["id"]!})==ids,"rechecking same file leaves stable canonical IDs")
    try snapshot(["C","missed","D","E","F","new1","new2"],"rollover",1200)
    try check(try db.unifiedRows().count==14,"rollover retains earlier merged history and adds only new suffix")
    try snapshot([],"empty",1300)
    try check(try db.unifiedRows().count==14,"empty Music history never clears stored history")
    try db.exportAll()
    try check(FileManager.default.fileExists(atPath:folder.appendingPathComponent("history.csv").path),"one unified history export")
    try check(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("recorded-plays.csv").path),"no separate recorded export generated")
    try check(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("music-history.csv").path),"no separate Music export generated")
    try check(try db.audit(full:true)["database_ok"] as? Bool==true,"unified provenance and database audit")
    // Music's repeat count wins over extra recorder segments in the covered run.
    let repeats=try Archive(folder:folder.appendingPathComponent("repeats"))
    for (i,name) in ["A","B","C","C","D"].enumerated() {
        try repeats.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?)",[name,"Song "+name,"Artist "+name,"Album "+name,stamp(base.addingTimeInterval(Double(i)*20)),stamp(base.addingTimeInterval(Double(i)*20+10)),stamp(base.addingTimeInterval(Double(i)*20+10)),10,100])
    }
    try repeats.syncRecordingsAndLibrary()
    let songs=["A","B","C","D"].map { name -> ImportedSong in
        var s=ImportedSong(title:"Song "+name);s.artist="Artist "+name;s.album="Album "+name;s.persistentID=name;return s
    }
    try repeats.ingest(HistorySnapshot(hash:"repeats",songs:songs,source:folder.appendingPathComponent("History.dat"),modified:stamp(base.addingTimeInterval(1000)),captured:base.addingTimeInterval(1000)))
    try repeats.syncUnifiedHistory(preferMusic:true)
    let merged=try repeats.unifiedRows()
    try check(merged.count==4,"Music controls repeat count, not recorder fragment count")
    try check(merged.first{$0["title"]=="Song C"}?["recording_segments"]=="2","both recording segments retained on the one authoritative Music entry")
    // A later same-song recording must not be pulled into an old snapshot.
    try repeats.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,ended_at,duration) VALUES (?,?,?,?,?,?,?,?)",["C","Song C","Artist C","Album C",stamp(base.addingTimeInterval(2000)),stamp(base.addingTimeInterval(2010)),stamp(base.addingTimeInterval(2010)),100])
    try repeats.syncRecordingsAndLibrary();try repeats.syncUnifiedHistory(preferMusic:true)
    try check(try repeats.unifiedRows().count==5,"recording after file capture remains separate")
    print("PASS: single canonical history/export, Music priority, missing-song recovery, anchored deduplication, supersession evidence, repeated segments, rollover, clear, stable IDs, later recordings, unified audit.")
}

func upgradeOnly(_ folder:URL) throws {
    let lease=try ArchiveLease(folder);defer { _=lease }
    let db=try Archive(folder:folder)
    try db.exec("UPDATE sessions SET ended_at=last_observed_at,end_reason='recorder_interruption' WHERE ended_at IS NULL")
    try db.meta("recorder_state","stopped");try db.meta("recorder_pid","")
    try db.syncRecordingsAndLibrary()
    let report=try db.audit(full:true)
    guard report["database_ok"] as? Bool==true else { throw AppError(message:"Unified history audit failed.") }
    try db.exportAll()
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:folder.appendingPathComponent("merge-summary.json"),options:.atomic)
    print(String(data:data,encoding:.utf8)!)
}
func historyTests() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-v2-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let db=try Archive(folder:folder),base=Date(timeIntervalSince1970:1_780_000_000)
    let source=folder.appendingPathComponent("Music Library.musiclibrary/Preferences/History.dat")
    func snap(_ names:[String],_ tag:String,_ time:Double=0,_ url:URL?=nil) -> HistorySnapshot {
        HistorySnapshot(hash:tag,songs:names.map { name in
            var s=ImportedSong(title:"Song "+name);s.artist="Artist "+name;s.album="Album "+name;s.catalogID=name;return s
        },source:url ?? source,modified:stamp(base.addingTimeInterval(time)),captured:base.addingTimeInterval(time))
    }
    func count(_ table:String) throws -> Int { Int(try db.rows("SELECT COUNT(*) n FROM \(table)").first!["n"]!)! }
    try db.ingest(snap(["A","B","C","C"],"one"))
    try check(try count("history_occurrences")==4,"baseline preserves consecutive repeats")
    try db.ingest(snap(["A","B","C","C"],"one",30))
    try check(try count("history_occurrences")==4 && count("history_snapshots")==1,"same file is idempotent")
    try db.ingest(snap(["A","B","C","C"],"metadata",60))
    try check(try count("history_occurrences")==4,"artwork or metadata changes add no plays")
    try db.ingest(snap(["B","C","C","D"],"roll",90))
    try check(try count("history_occurrences")==5,"rollover adds only new suffix")
    let bounded=try db.rows("SELECT * FROM history_occurrences WHERE window_start IS NOT NULL")
    try check(bounded.count==1,"frequent live checks provide an observation window")
    let recorder=try Recorder(db)
    var collision=ImportedSong(title:"Song A");collision.artist="Different artist";collision.album="Different album";collision.catalogID="different-A"
    let collisionID=try db.resolve(collision)
    let originalID=try db.rows("SELECT track_id FROM track_aliases WHERE kind='catalog' AND value='A'").first!["track_id"]!
    try check(collisionID != originalID,"same title with a different artist must not merge")
    // An undated baseline song must not be merged with a later recording of it.
    try db.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?)",["localA","Song A","Artist A","Album A",stamp(base),stamp(base.addingTimeInterval(10)),stamp(base.addingTimeInterval(10)),10,100])
    try db.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?)",["localD","Song D","Artist D","Album D",stamp(base.addingTimeInterval(70)),stamp(base.addingTimeInterval(89)),stamp(base.addingTimeInterval(89)),19,100])
    try db.syncRecordingsAndLibrary();try db.reconcile()
    try check(try count("history_matches")==1,"only unique live-window matches may link")
    try check(try db.rows("SELECT m.* FROM history_matches m JOIN recording_tracks r ON r.session_id=m.session_id JOIN track_aliases a ON a.track_id=r.track_id WHERE a.kind='catalog' AND a.value='A'").isEmpty,"baseline overlap is never presented as an exact match")
    try db.ingest(snap([],"clear",120))
    try check(try count("history_occurrences")==5,"clearing Music history preserves archive")
    try db.ingest(snap(["E","F","G"],"afterclear",150))
    try check(try count("history_occurrences")==5,"disjoint snapshot stored without guessing counts")
    try db.ingest(snap(["E","F","G","H"],"resume",180))
    try check(try count("history_occurrences")==6,"reliable new suffix recovers after an uncertain snapshot")
    try db.ingest(snap(["A","B","C","A","B","C"],"periodic",210))
    try db.ingest(snap(["A","B","C","A","B","C","A","B","C"],"ambiguous",240))
    try check(try count("history_occurrences")==6,"multiple possible overlaps are not guessed")
    // Invalid identifiers must roll back the entire import, including its check metadata.
    var conflict=ImportedSong(title:"Song X");conflict.catalogID="A";conflict.persistentID="localD"
    let prior=try count("history_snapshots"),lastCheck=try db.value("history_observed_at")
    do {
        try db.ingest(HistorySnapshot(hash:"bad",songs:[conflict],source:source,modified:stamp(),captured:Date()))
        throw AppError(message:"Self-test: conflicting identifiers accepted")
    } catch let e as AppError where e.message.contains("Conflicting song identifiers") { }
    try check(try count("history_snapshots")==prior && db.value("history_observed_at")==lastCheck,"failed import is atomic")
    try db.syncRecordingsAndLibrary()
    let health=try db.audit(full:true)
    try check(health["database_ok"] as? Bool==true,"integrity and evidence coverage checks")
    try db.exportAll()
    // Parser rejects a partial file without changing the archive.
    let bad=folder.appendingPathComponent("bad.dat")
    try Data("<?xml version=\"1.0\"?><plist>".utf8).write(to:bad)
    do { _=try HistorySnapshot.read(bad);throw AppError(message:"Self-test: truncated file accepted") }
    catch let e as AppError where e.message.hasPrefix("Self-test:") { throw e }
    catch { }
    _=recorder

    let rankingFolder=folder.appendingPathComponent("ranking"),rank=try Archive(folder:rankingFolder),reader=try Recorder(rank)
    var library:[[String:Any]]=[]
    for a in 0..<5 { for n in 0..<5 {
        library.append(["persistent_id":"\(a)-\(n)","title":"\(a) song \(n)","artist":"Artist \(a)","album":"Album \(a)","genre":a<3 ? "Pop" : "Rock","album_artist":"Artist \(a)","duration":180,"play_count":5])
    } }
    try reader.library(["running":true,"tracks":library])
    try rank.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?)",["0-0","0 song 0","Artist 0","Album 0",stamp(base.addingTimeInterval(-180)),stamp(base),stamp(base),170,180])
    try rank.syncRecordingsAndLibrary()
    let before=try rank.recommendations(now:base.addingTimeInterval(90000),limit:25)
    var duplicate=ImportedSong(title:"0 song 0");duplicate.artist="Artist 0";duplicate.album="Album 0";duplicate.catalogID="duplicate-source"
    try rank.ingest(HistorySnapshot(hash:"same-play",songs:[duplicate],source:source,modified:stamp(base),captured:base))
    let after=try rank.recommendations(now:base.addingTimeInterval(90000),limit:25)
    let overlapMatches=zip(before,after).allSatisfy{$0.id==$1.id && abs($0.score-$1.score)<0.00000001}
    let mismatches=zip(before,after).filter{$0.id != $1.id || abs($0.score-$1.score)>=0.00000001}.map {
        "\($0.title)=\(String(format:"%.17g",$0.score)) → \($1.title)=\(String(format:"%.17g",$1.score))"
    }
    try check(overlapMatches,"overlapping imported/recorded signals do not inflate preference: \(mismatches.joined(separator:"; "))")
    try check(!after.contains{$0.reason.contains("listening to now")},"old/paused sessions do not become current listening")
    var recommendations=try rank.recommendations(now:base)
    try check(!recommendations.isEmpty && recommendations.prefix(3).contains{$0.artist=="Artist 0"},"current listening affects ranking")
    try check(!recommendations.contains{$0.title=="0 song 0"},"recent track cooldown")
    try check(Set(recommendations.map{$0.id}).count==recommendations.count,"recommendations contain no duplicates")
    try check(Dictionary(grouping:recommendations,by:{$0.artist}).values.allSatisfy{$0.count<=2},"artist variety where enough candidates exist")
    let rejected=recommendations[0].id
    try rank.feedback(rejected,"less",at:base)
    try check(try !rank.recommendations(now:base).contains{$0.id==rejected},"less feedback removes the track")
    let later=try rank.recommendations(now:base)[0].id
    try rank.feedback(later,"like",at:base);try rank.feedback(later,"later",at:base)
    try check(try !rank.recommendations(now:base).contains{$0.id==later},"not now temporarily suppresses")
    recommendations=try rank.recommendations(now:base.addingTimeInterval(90000),limit:25)
    try check(recommendations.contains{$0.id==later && $0.reason.contains("favorite")},"temporary feedback expires without erasing likes")
    let noHistory=try Archive(folder:folder.appendingPathComponent("empty"))
    try check(try noHistory.recommendations().isEmpty,"empty archive is usable")
    print("PASS: history imports, consecutive repeats, idempotence, metadata-only updates, rollover, clear, ambiguous overlap, recovery, atomic rollback, live-window reconciliation, integrity, recommendations, cooldown, diversity, feedback, empty archive.")
}

func maintenance(_ folder:URL) throws {
    let lease=try ArchiveLease(folder);defer { _=lease }
    let db=try Archive(folder:folder)
    try db.exec("UPDATE sessions SET ended_at=last_observed_at,end_reason='recorder_interruption' WHERE ended_at IS NULL")
    try db.meta("recorder_state","stopped");try db.meta("recorder_pid","")
    try db.syncRecordingsAndLibrary()
    let saved=try db.value("history_source_path")
    let source=URL(fileURLWithPath:saved.isEmpty ? folder.appendingPathComponent("History.dat").path : saved)
    try db.meta("history_source_path",source.path)
    let snapshot=try HistorySnapshot.read(source)
    let note=try db.ingest(snapshot)
    try db.reconcile()
    try db.syncUnifiedHistory(preferMusic:true)
    let report=try db.audit(full:true)
    guard report["database_ok"] as? Bool==true else { throw AppError(message:"Database checks failed; see database-health.json.") }
    try db.exportAll()
    let recs=try db.recommendations()
    var summary=report
    summary["history_import"]=note;summary["snapshot_entries"]=snapshot.songs.count
    summary["recommendations"]=recs.map{["title":$0.title,"artist":$0.artist,"reason":$0.reason]}
    summary["history_source_is_live"]=isLiveHistory(source)
    let data=try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:folder.appendingPathComponent("maintenance-summary.json"),options:.atomic)
    print(String(data:data,encoding:.utf8)!)
}


@MainActor func automaticQueueTests() throws {
    func expect(_ value:Bool,_ message:String) throws {
        guard value else { throw AppError(message:"Automatic queue test: "+message) }
    }
    let a="0000000000000001",b="0000000000000002",c="0000000000000003",d="0000000000000004"
    func sample(_ id:String,_ position:Double=0,_ state:String="playing") -> Sample {
        Sample(["running":true,"state":state,"persistent_id":id,"title":"Test", "position":position,"duration":180])
    }
    var queue=AutomaticQueue()
    queue.start(queued:[[b],[c],[d]],currentID:a)
    queue.observe(sample(a));queue.observe(sample(a,100))
    queue.observe(sample(a,100,"paused"));queue.observe(sample(b,0,"paused"))
    try expect(queue.pendingReplacements==0,"same track, seeks and pauses add nothing")
    queue.observe(sample(b))
    try expect(queue.pendingReplacements==1,"finishing the selected song requests one replacement")
    queue.pendingReplacements=0
    queue.observe(sample(b,2));queue.observe(sample(c))
    try expect(queue.pendingReplacements==1,"a skip after two seconds requests one replacement")
    queue.observe(sample(c,3))
    try expect(queue.pendingReplacements==1,"repeated observations cannot count the same transition twice")
    queue.start(queued:[[b],[c],[d]],currentID:a)
    queue.observe(sample(d))
    try expect(queue.pendingReplacements==3 && queue.songs.count==1,"multiple skipped known songs between polls are accounted once")
    queue.start(queued:[[c],[d]],albumIDs:[a,b])
    queue.observe(sample(a));queue.observe(sample(b));queue.observe(sample(b,170))
    try expect(queue.waitingForAlbum && queue.pendingReplacements==0,"album track changes and skips never refill")
    queue.observe(sample(c))
    try expect(!queue.waitingForAlbum && queue.pendingReplacements==0,"entering the first follow-up ends album waiting without adding a song")
    queue.observe(sample(c,2));queue.observe(sample(d))
    try expect(queue.pendingReplacements==1,"leaving an album follow-up refills even after a short skip")
    queue.start(queued:[[c],[d]],albumIDs:[a,b]);queue.observe(sample(d))
    try expect(queue.pendingReplacements==1,"a skipped first follow-up missed between polls is replenished")
    queue.start(queued:[[c]],currentID:a);queue.observe(sample(b))
    try expect(queue.enabled && queue.pendingReplacements==0,"pre-existing queued music does not cancel monitoring or trigger additions")
    queue.observe(sample(c))
    try expect(queue.pendingReplacements==1,"monitoring resumes when our queued song arrives")
    queue.observe(Sample(["running":true,"state":"stopped"]))
    try expect(queue.pendingReplacements==1,"a transient stopped state adds nothing")
    queue.observe(Sample(["running":false]))
    try expect(!queue.enabled && queue.pendingReplacements==0,"closing Music stops automatic queueing")

    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-continuous-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let model=try Model(folder:folder)
    for n in 1...18 {
        var song=ImportedSong(title:"Continuous \(n)");song.persistentID=String(format:"%016X",n)
        let id=try model.archive.resolve(song);try model.archive.feedback(id,"like")
    }
    model.catalogResolveOverride={ requests in
        requests.enumerated().map { index,request in
            CatalogQueueSong(index:index,persistentID:(request["ids"] as! [String])[0],catalogID:String(index+1))
        }
    }
    model.menuSongBusy=true // Keep this test completely isolated from real Music.
    var additions=0
    model.queueAppendOverride={_ in additions += 1;return 1}
    // A busy append defers the replacement rather than losing the transition.
    model.automaticQueue.start(queued:[[b],[c]],currentID:a)
    model.playbackTrackID="busy"
    model.observeAutomaticQueue(sample(b))
    try expect(additions==0,"monitor never races an in-flight queue action")
    model.playbackTrackID=nil
    model.menuSample=sample(b)
    model.observeAutomaticQueue(sample(b))
    let deadline=Date().addingTimeInterval(5)
    while model.playbackTrackID != nil && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    try expect(!model.recording && additions==1 && model.automaticQueue.enabled,"recording-off monitor appends exactly one replacement through the existing queue path")
    try expect(model.automaticQueue.pendingReplacements==0,"confirmed transition debt is cleared")
    let baselineID=try model.archive.rows("SELECT track_id FROM track_aliases WHERE value=?",[a]).first!["track_id"]!
    let next=try model.archive.automaticQueueSongs(excluding:[],currentPersistentID:nil,limit:100,excludingPersistentIDs:model.automaticQueue.knownIDs)
    try expect(!next.contains{$0.id==baselineID},"a consumed pre-existing current song cannot be recommended again with recording off")
    let count=try model.archive.rows("SELECT * FROM recommendation_feedback").count
    model.queueAppendOverride={_ in throw AppError(message:"Queue unavailable")}
    model.observeAutomaticQueue(sample(c))
    let failureDeadline=Date().addingTimeInterval(5)
    while model.playbackTrackID != nil && Date()<failureDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    try expect(!model.automaticQueue.enabled && model.playbackError.contains("Queue unavailable"),"queue failure stops automatic retries and exposes the error")
    try expect(try model.archive.rows("SELECT * FROM recommendation_feedback").count==count && model.archive.rows("SELECT * FROM sessions").isEmpty,"replacements create no Likes or listening history")
    print("PASS: automatic queue finishes/skips, album gating, pause/seek stability, catch-up, recording-off refill, serialized work, failures and no invented history.")
}
