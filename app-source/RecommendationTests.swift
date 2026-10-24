import Foundation
import CryptoKit

func recommendationTests() throws {
    try recommendationDifferentialTests()
    func expect(_ value:Bool,_ message:String) throws {
        guard value else { throw AppError(message:"Recommendation test: "+message) }
    }
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-taste-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let db=try Archive(folder:folder),now=Date(timeIntervalSince1970:1_790_000_000)
    func song(_ n:Int,artist:String,album:String,count:Int=40,days:Double?=20,number:Int=1,total:Int=1,disc:Int=1,discs:Int=1,guest:String?=nil) -> [String:Any] {
        var row:[String:Any]=["persistent_id":String(format:"%016X",n),"title":"Song \(n)","artist":guest ?? artist,"album":album,
            "album_artist":artist,"genre":"Pop","duration":180,"play_count":count,"disc_number":disc,"disc_count":discs,"track_number":number,"track_count":total]
        if let days { row["last_played"]=stamp(now.addingTimeInterval(-days*86400)) }
        return row
    }
    func load(_ rows:[[String:Any]]) throws { try db.ingestLibrary(["running":true,"tracks":rows]) }
    func id(_ n:Int) throws -> String {
        try db.rows("SELECT track_id FROM track_aliases WHERE kind='persistent' AND value=?",[String(format:"%016X",n)]).first!["track_id"]!
    }
    func record(_ n:Int,at date:Date,heard:Double=180) throws {
        let row=try db.rows("SELECT * FROM library_tracks WHERE persistent_id=?",[String(format:"%016X",n)]).first!
        try db.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,last_listening_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?,?)",
            [row["persistent_id"],row["title"],row["artist"],row["album"],stamp(date),stamp(date.addingTimeInterval(heard)),stamp(date.addingTimeInterval(heard)),stamp(date.addingTimeInterval(heard)),heard,180])
    }
    var rows:[[String:Any]]=[]
    for n in 1...8 { rows.append(song(n,artist:"Old artist \(n)",album:"Old \(n)",days:Double(10+n))) }
    for n in 9...20 { rows.append(song(n,artist:"Hot artist \(n)",album:"Hot \(n)",count:200,days:0.2)) }
    rows.append(song(21,artist:"Familiar A",album:"Familiar A",days:2))
    rows.append(song(22,artist:"Familiar B",album:"Familiar B",days:2))
    rows.append(song(23,artist:"Explore A",album:"Explore A",count:0,days:nil))
    rows.append(song(24,artist:"Explore B",album:"Explore B",count:0,days:nil))
    rows.append(song(25,artist:"Unknown date",album:"Unknown date",days:nil))
    try load(rows)
    try db.feedback(id(9),"like",at:now)
    let initial=try db.recommendations(now:now)
    for _ in 0..<20 {
        let repeatBatch=try db.recommendations(now:now)
        try expect(initial.map{$0.id}==repeatBatch.map{$0.id} && initial.map{$0.score}==repeatBatch.map{$0.score},"identical evidence always produces identical scores and ordering")
    }
    try expect(initial.count==10,"eligible candidates fill a batch")
    try expect(initial.prefix(6).allSatisfy{$0.bucket=="Rediscover"},"six comeback positions precede familiar and discovery positions")
    try expect(initial.suffix(2).allSatisfy{$0.bucket=="Explore your library"},"two discovery positions when candidates exist")
    let hotIDs=try Set((9...20).map{try id($0)})
    try expect(!initial.contains{hotIDs.contains($0.id)},"24-hour cooldown covers every recent song, including explicit likes")
    let all=try db.recommendations(now:now,limit:100)
    let unknownID=try id(25)
    try expect(all.first{$0.id==unknownID}?.bucket != "Rediscover","unknown dates do not imply neglect")
    try expect(try db.recommendations(now:now,limit:0).isEmpty,"zero limit is valid")
    let exampleRows=(0..<4).map{song(100+$0,artist:"Example Ensemble",album:"Example Album",number:$0+1,total:4,guest:$0==2 ? "Example Ensemble & Guest" : nil)}
    try load(exampleRows)
    let exampleAlbum=try db.albumCollections().first{$0.title=="Example Album"}!
    try expect(exampleAlbum.tracks.count==4 && exampleAlbum.artist=="Example Ensemble","guest credits never split an album or change its artist")
    try expect(try db.albumMode(exampleAlbum,feedback:db.recommendationFeedback(now:now)) == .automatic,"new albums start in automatic mode without artist-specific preferences")
    try db.feedback(exampleAlbum.id,"mode_album",at:now)
    let album=try db.recommendations(now:now,limit:100).first{$0.id==exampleAlbum.id}
    try expect(album?.kind == .album && album?.playbackIssue==nil,"An explicitly selected album is offered as a complete whole-album recommendation")
    try db.rememberForYouPlayback(album!,at:now)
    try expect(try !db.recommendations(now:now,limit:100).contains{$0.albumID==exampleAlbum.id},"starting an album cools both the album and its songs")
    try expect(try db.recommendations(now:now.addingTimeInterval(86401),limit:100).contains{$0.id==exampleAlbum.id},"album selection cooldown expires")
    try db.meta("for_you_playback_cooldowns","")
    try expect(try !db.recommendations(now:now,limit:100).contains{$0.kind == .song && $0.albumID==exampleAlbum.id},"album-only play evidence does not produce scattered singles")
    let request=try db.playbackRequest(for:album!),items=request["tracks"] as! [[String:Any]]
    try expect((items.first?["ids"] as? [String])?.first==String(format:"%016X",100),"album playback always begins with track one")
    try db.feedback(exampleAlbum.id,"mode_tracks",at:now)
    try expect(try db.recommendations(now:now,limit:100).contains{$0.kind == .song && $0.albumID==exampleAlbum.id},"manual individual-song mode overrides album preference")
    try db.feedback(exampleAlbum.id,"mode_album",at:now)
    try db.feedback(id(100),"like",at:now)
    let firstExampleID=try id(100)
    try expect(try db.recommendations(now:now,limit:100).contains{$0.id == firstExampleID},"an explicit single like remains an independent preference")
    try db.feedback(exampleAlbum.id,"like",at:now)
    try db.feedback(exampleAlbum.id,"later",at:now)
    try expect(try !db.recommendations(now:now).contains{$0.albumID==exampleAlbum.id},"album Not now cannot be bypassed by its liked singles")
    let state=try db.recommendationFeedback(now:now.addingTimeInterval(90000))[exampleAlbum.id]!
    try expect(state.liked && !state.later && state.mode == .album,"temporary suppression expires without erasing album like or listening mode")
    try db.undoRecommendationFeedback()
    try expect(try db.recommendationFeedback(now:now)[exampleAlbum.id]?.liked == true,"Undo restores the previous target state across feedback types")
    try db.feedback(exampleAlbum.id,"reset",at:now)
    try db.feedback(id(100),"reset",at:now)
    var oneRecent=exampleRows
    oneRecent[0]["last_played"]=stamp(now.addingTimeInterval(-7200))
    try load(oneRecent)
    try expect(try db.recommendations(now:now,limit:100).contains{$0.id==exampleAlbum.id},"one recent single does not count as replaying the whole album")
    try load(exampleRows.map { row in var r=row;r["last_played"]=stamp(now.addingTimeInterval(-7200));return r })
    try expect(try !db.recommendations(now:now,limit:100).contains{$0.albumID==exampleAlbum.id},"recent album coverage cools the album and all component singles")
    let learnedRows=(0..<5).map{song(200+$0,artist:"Learned album artist",album:"Learned album",number:$0+1,total:5,guest:"Guest \($0)")}
    try load(learnedRows)
    for days in [20.0,10.0] { for n in 0..<5 { try record(200+n,at:now.addingTimeInterval(-days*86400+Double(n)*190)) } }
    try db.syncRecordingsAndLibrary()
    let learned=try db.albumCollections().first{$0.title=="Learned album"}!
    try expect(try db.recommendations(now:now,limit:100).contains{$0.id==learned.id && $0.kind == .album},"two independent substantial album runs learn album listening mode")
    try db.feedback(learned.id,"mode_tracks",at:now)
    try expect(try !db.recommendations(now:now,limit:100).contains{$0.id==learned.id},"manual track mode overrides inferred album mode")
    try db.feedback(learned.id,"mode_auto",at:now)
    try expect(try db.recommendations(now:now,limit:100).contains{$0.id==learned.id},"automatic mode can be restored")
    try db.feedback(id(200),"less",at:now)
    let blocked=try db.recommendations(now:now,limit:100).first{$0.id==learned.id}
    try expect(blocked?.playbackIssue != nil,"album playback cannot bypass Less on a song")
    var refused=false
    if let blocked { do { _=try db.playbackRequest(for:blocked) } catch { refused=true } }
    try expect(refused,"blocked album playback fails before a Music command")
    let multiRows=[song(300,artist:"Example Band",album:"Two discs",number:2,total:2,disc:2,discs:2),
        song(301,artist:"Example Band",album:"Two discs",number:1,total:2,disc:1,discs:2),
        song(302,artist:"Example Band",album:"Two discs",number:1,total:2,disc:2,discs:2),
        song(303,artist:"Example Band",album:"Two discs",number:2,total:2,disc:1,discs:2)]
    try load(multiRows)
    let multi=try db.albumCollections().first{$0.title=="Two discs"}!
    try expect(multi.playbackIssue==nil && multi.orderedTracks.map{$0.id} == [try id(301),try id(303),try id(302),try id(300)],"disc order precedes track number")
    try load([song(400,artist:"Example Band",album:"Incomplete",number:2,total:3)])
    let incomplete=try db.albumCollections().first{$0.title=="Incomplete"}!
    try expect(incomplete.playbackIssue == nil,"an album with only saved track two is playable from that saved song")
    let savedNumbers=[1,3,4,5,6,7,8,10,11]
    try load(savedNumbers.reversed().map{song(500+$0,artist:"Example Group",album:"Saved subset",number:$0,total:12)})
    let subset=try db.albumCollections().first{$0.title=="Saved subset"}!
    try db.feedback(subset.id,"mode_album",at:now)
    try expect(subset.playbackIssue==nil && subset.orderedTracks.map{$0.number}==savedNumbers,"nine saved songs from a twelve-song album remain playable in release order")
    let subsetRec=try db.recommendations(now:now,limit:100).first{$0.id==subset.id}
    try expect(subsetRec?.playbackIssue==nil && subsetRec?.trackIDs.count==9,"partial library album remains eligible for Play album and Next for you")
    let subsetRequest=try db.playbackRequest(for:subsetRec!),savedItems=subsetRequest["tracks"] as! [[String:Any]]
    try expect(savedItems.compactMap{$0["number"] as? Int}==savedNumbers,"album request includes only saved tracks and keeps numbering gaps")
    let sparse=AlbumCollection(id:"sparse",artist:"Artist",title:"Sparse",tracks:[
        AlbumTrack(id:"later",artist:"Artist",title:"Later",disc:3,discs:3,number:7,count:12),
        AlbumTrack(id:"first",artist:"Artist",title:"First saved",disc:2,discs:3,number:4,count:10)])
    try expect(sparse.playbackIssue==nil && sparse.orderedTracks.map{$0.id}==["first","later"],"unsaved opening tracks and entire unsaved discs never block album playback")
    var ambiguous=sparse
    ambiguous.tracks.append(AlbumTrack(id:"duplicate",artist:"Artist",title:"Duplicate",disc:2,discs:3,number:4,count:10))
    try expect(ambiguous.playbackIssue != nil,"duplicate saved disc/track positions remain ambiguous")
    try load([song(401,artist:"Other artist",album:"Two discs")])
    try expect(try db.albumCollections().filter{$0.title=="Two discs"}.count==2,"same album title under different album artists stays separate")
    var missing=song(402,artist:"Guest",album:"Unknown owner");missing.removeValue(forKey:"album_artist")
    try load([missing])
    try expect(try db.recommendationForTrack(id(402))?.artist=="Unknown album artist","missing album artist never falls back to track artist")
    try expect(try db.rows("SELECT COUNT(*) n FROM sessions").first?["n"]=="10","ratings, album modes and ranking do not fabricate listening events")
    try expect(try db.audit(full:true)["database_ok"] as? Bool==true,"recommendation changes preserve history integrity")
    print("PASS: comeback allocation, all-song cooldown, album artists, album sessions, manual preferences, album/single feedback, incomplete and multi-disc albums, unknown dates and history integrity.")
}

func recommendationMigrationTests() throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-v4-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    var trackID=""
    do {
        let db=try Archive(folder:folder)
        var song=ImportedSong(title:"Original history");song.persistentID="0000000000000001"
        trackID=try db.resolve(song)
        try db.exec("INSERT INTO track_feedback(track_id,kind,created_at) VALUES (?,'like',?)",[trackID,stamp()])
        try db.exec("DROP TABLE recommendation_feedback");try db.exec("DROP TABLE track_album_metadata");try db.exec("PRAGMA user_version=3")
    }
    let db=try Archive(folder:folder)
    guard try db.recommendationFeedback(now:Date())[trackID]?.liked == true,
          try db.rows("SELECT * FROM music_tracks").count==1,
          try db.rows("PRAGMA user_version").first?["user_version"]=="4",
          FileManager.default.fileExists(atPath:try db.value("recommendations_upgrade_backup")) else { throw AppError(message:"v4 migration lost existing history, feedback or its backup") }
    print("PASS: backed-up v3 to v4 migration preserves identities and feedback.")
}

// Full metadata and raw Double bits must agree, not just ranking invariants.
func recommendationFingerprint(_ items:[Recommendation]) -> String {
    items.map { r in
        [r.id,r.title,r.artist,r.album,r.catalogID,r.reason,String(r.score.bitPattern),r.bucket,
         r.kind.rawValue,r.albumID ?? "<nil>",r.trackIDs.joined(separator:"|"),r.playbackIssue ?? "<nil>"].joined(separator:"\u{1f}")
    }.joined(separator:"\n")
}

func recommendationDifferentialTests() throws {
    func check(_ actual:[Recommendation],_ expected:[Recommendation],_ context:String) throws {
        guard recommendationFingerprint(actual)==recommendationFingerprint(expected) else {
            throw AppError(message:"Recommendation differential mismatch: "+context)
        }
    }
    struct Random {
        var state:UInt64=0x521c_73a9
        mutating func next(_ n:Int) -> Int {
            state=state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(n))
        }
    }
    var random=Random()
    var fingerprints=Data(),fallbackCounts=[0,0,0,0]
    let limits=[-1,0,1,10,100,240]
    // Include exact and near ties, empty vectors, shared albums, missing artists,
    // exhausted buckets/artist caps, and album/song conflicts in arbitrary input order.
    for fixture in 0..<36 {
        var candidates:[Recommendation]=[],vectors:[String:[String:Double]]=[:]
        let count=fixture==0 ? 0 : 25+random.next(100)
        for i in 0..<count {
            let id=String(format:"candidate-%04d",i),album=i%5==0 ? nil : "album-\(i/4)"
            let kind:RecommendationKind=i%4==0 ? .album : .song
            let artist=fixture%4==0 ? "Same artist" : ["", "ARTIST A", "artist a", "Beyoncé", "Beyonce", "Other \(random.next(12))"][random.next(6)]
            let buckets=["Rediscover","Familiar","Explore your library"]
            let score=fixture%3==0 ? 0.5 : Double(random.next(5))/10 + (i%7==0 ? Double.ulpOfOne : 0)
            candidates.append(Recommendation(id:id,title:id,artist:artist,album:album ?? "",catalogID:"",reason:"fixture \(i)",score:score,
                bucket:buckets[fixture%5==0 ? 1 : random.next(3)],kind:kind,albumID:album,trackIDs:["track-\(i)"],playbackIssue:i%9==0 ? "blocked" : nil))
            var vector:[String:Double]=[:]
            for _ in 0..<random.next(5) { vector["feature-\(random.next(9))"]=Double(random.next(4))/4 }
            vectors[id]=vector
        }
        // Reversing input and constructing dictionaries here exercises tie independence.
        candidates.reverse()
        let prepared=vectors.mapValues{RecommendationFeatures($0)}
        for limit in limits {
            let metrics=RecommendationMetrics()
            let actual=selectRecommendations(candidates,vectors:prepared,limit:limit,metrics:metrics)
            fingerprints.append(Data(recommendationFingerprint(actual).utf8))
            for tier in 0..<4 { fallbackCounts[tier] += metrics.selectedFallbackCounts[tier] }
            try check(actual,
                      selectRecommendationsReference(candidates,vectors:vectors,limit:limit),"selector fixture \(fixture), limit \(limit)")
            guard metrics.selectionSimilarityCalls<=count*max(0,limit-1) else { throw AppError(message:"Selection exceeded O(NK) similarity bound") }
        }
    }
    guard fallbackCounts.allSatisfy({$0>0}) else { throw AppError(message:"Differential fixtures did not exercise every selection fallback") }
    let now=Date(timeIntervalSince1970:1_790_000_000)
    for fixture in 0..<12 {
        var tracks:[[String:String]]=[],library:[[String:String]]=[],history:[[String:String]]=[],events:[[String:String]]=[]
        var albums:[AlbumCollection]=[],feedback:[String:RecommendationFeedback]=[:],modes:[String:AlbumListeningMode]=[:]
        let count=30+random.next(70)
        for i in 0..<count {
            let id="track-\(i)",artist=i%11==0 ? "" : "Artist \(i/6)",title=i%13==0 ? "" : "Album \(i/3)"
            tracks.append(["id":id,"title":"Title \(i)","album_artist":artist,"album_title":title,"genre":i%7==0 ? "" : "Genre \(random.next(5))","duration":"180"])
            var row=["track_id":id,"play_count":String(random.next(100))]
            if i%7 != 0 { row["last_played"]=stamp(now.addingTimeInterval(-Double(random.next(25))*86400)) }
            library.append(row)
            if i%3==0 { history.append(["track_id":id,"music_snapshot_id":"1"]) }
            if i%2==0 {
                let date=now.addingTimeInterval(-Double(i)*190-Double(fixture%3)*86400)
                let event=["id":"event-\(i)","track_id":id,"first_observed_at":stamp(date),"last_listening_at":stamp(date.addingTimeInterval(170)),"duration":"180","observed_listening_seconds":"170"]
                events.append(event);if i%10==0 { events.append(event) }
            }
            if i%8==0 { feedback[id]=RecommendationFeedback(liked:true) }
            if i%17==0 { feedback[id]=RecommendationFeedback(less:true) }
            if let albumID=albumIdentity(artist:artist,title:title) {
                let track=AlbumTrack(id:id,artist:artist,title:title,disc:1,discs:1,number:i%3+1,count:3)
                if let index=albums.firstIndex(where:{$0.id==albumID}) { albums[index].tracks.append(track) }
                else { albums.append(AlbumCollection(id:albumID,artist:artist,title:title,tracks:[track]));modes[albumID]=i%2==0 ? .album : .tracks }
            }
        }
        events.sort{($0["first_observed_at"] ?? "")<($1["first_observed_at"] ?? "")}
        let snapshot=RecommendationSnapshot(now:now,feedback:feedback,albums:albums,playbackCooldowns:fixture%2==0 ? ["track-3":1] : [:],modes:modes,trackRows:tracks,historyRows:history,libraryRows:library,eventRows:events)
        for limit in limits {
            let actual=snapshot.scored(limit:limit)
            fingerprints.append(Data(recommendationFingerprint(actual).utf8))
            try check(actual,snapshot.scoredReference(limit:limit),"snapshot \(fixture), limit \(limit)")
        }
    }
    print("Differential fingerprint: \(SHA256.hash(data:fingerprints).map{String(format:"%02x",$0)}.joined())")
    print("PASS: full scorer and selector differential fixtures, exact scores/metadata, tie/fallback/conflict/limit cases and O(NK) similarity bound.")
}
