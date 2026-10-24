import Foundation

private final class AlbumReserveLog {
    private let lock=NSLock()
    private var values:[String]=[]
    func add(_ value:String) { lock.lock();values.append(value);lock.unlock() }
    var items:[String] { lock.lock();defer{lock.unlock()};return values }
}
@MainActor func cachedAlbumTests() throws {
    func expect(_ value:Bool,_ message:String) throws { if !value { throw AppError(message:"Cached album test: "+message) } }
    func wait(_ condition:()->Bool,_ message:String) throws {
        let deadline=Date().addingTimeInterval(3)
        while !condition() && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
        try expect(condition(),message)
    }
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-album-reserve-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    func fixture(_ name:String) throws -> (Model,Recommendation,[Recommendation]) {
        let model=try Model(folder:root.appendingPathComponent(name)),now=Date()
        try model.allowCollection(recordOnLaunch:false)
        let rows=(1...12).map { n -> [String:Any] in
            let album=n<=3
            return ["persistent_id":String(format:"%016X",n),"title":"Reserved \(n)","artist":album ? "Pink Floyd" : "Artist \(n)","album_artist":album ? "Pink Floyd" : "Artist \(n)","album":album ? "Selected album" : "Album \(n)","duration":180,"play_count":20,"last_played":stamp(now.addingTimeInterval(-20*86400)),"disc_number":1,"disc_count":1,"track_number":album ? n : 1,"track_count":album ? 3 : 1]
        }
        try model.archive.ingestLibrary(["running":true,"tracks":rows])
        model.menuSongBusy=true
        let collection=try model.archive.albumCollections().first{$0.title=="Selected album"}!
        let album=Recommendation(id:collection.id,title:collection.title,artist:collection.artist,album:collection.title,catalogID:"",reason:"Fixture",score:1,bucket:"Familiar",kind:.album,albumID:collection.id,trackIDs:collection.orderedTracks.map{$0.id},playbackIssue:nil)
        let songs=try (1...6).map { n in try model.archive.rows("SELECT track_id FROM track_aliases WHERE value=? AND kind='persistent'",[String(format:"%016X",n)]).first!["track_id"]! }.map{try model.archive.recommendationForTrack($0)!}
        model.suggestions=[album,songs[0]]+Array(songs.suffix(3))
        model.catalogResolveOverride={ requests in requests.enumerated().map { index,request in
            let pid=(request["ids"] as! [String])[0]
            return CatalogQueueSong(index:index,persistentID:pid,catalogID:String(UInt64(pid,radix:16)!+10000))
        } }
        return (model,album,Array(songs.suffix(3)))
    }
    func response(_ request:[String:Any]) throws -> [String:Any] {
        let tracks=request["tracks"] as! [[String:Any]],following=request["following_tracks"] as! [[String:Any]]
        try expect(following.allSatisfy{($0["kind"] as? String)=="song" && !($0["ids"] as? [String] ?? []).isEmpty},"generated follow-up payload must satisfy the shipped play.js song schema")
        let ids=tracks.map{($0["ids"] as! [String])[0]}
        return ["status":"playing","persistent_id":ids[0],"track_count":ids.count,"from_start":true,"album_ids":ids,"following_ids":following.map{($0["ids"] as! [String])[0]},"playlist_id":"MOCK"]
    }
    let (model,album,future)=try fixture("cached"),plays=AlbumReserveLog(),inserted=AlbumReserveLog(),rankCalls=AlbumReserveLog(),gate=DispatchSemaphore(value:0)
    defer { gate.signal() }
    model.automaticScoreOverride={ snapshot in rankCalls.add("rank");_=gate.wait(timeout:.now()+10);return snapshot.scored(limit:100) }
    model.playbackStartOverride={ request in
        let ids=(request["following_tracks"] as! [[String:Any]]).map{($0["ids"] as! [String])[0]}
        plays.add(ids.joined(separator:","));return try response(request)
    }
    model.queueAppendOverride={ request in inserted.add(request["catalog_id"] as! String);return 1 }
    let expected=try future.map{try model.archive.playbackIDs(for:$0.id).first!}
    model.play(album)
    try wait({plays.items.count==1 && model.automaticQueue.waitingForAlbum && model.preparedAutomaticSongs.count==2 && !rankCalls.items.isEmpty},"album starts with its cached follow-up while next-batch ranking blocks")
    try expect(plays.items==[expected[0]] && inserted.items.isEmpty,"source playlist follows the full album with exactly one outside-album cached song")
    let firstAlbumID=try model.archive.playbackIDs(for:album.trackIDs[0]).first!
    model.observeAutomaticQueue(Sample(["running":true,"state":"playing","title":"Album","persistent_id":firstAlbumID]))
    try expect(inserted.items.isEmpty,"native queue insertion remains gated during album playback")
    let followup=Sample(["running":true,"state":"playing","title":"Follow-up","persistent_id":expected[0]])
    model.menuSample=followup;model.observeAutomaticQueue(followup)
    try wait({inserted.items.count==1 && model.playbackTrackID==nil},"cached C submits when the album's B follow-up starts")
    try expect(inserted.items==[String(UInt64(expected[1],radix:16)!+10000)],"album continuation keeps the click-reserved C order")
    model.stopAutomaticQueue();gate.signal()

    let (empty,emptyAlbum,emptyChoices)=try fixture("empty"),emptyPlays=AlbumReserveLog(),emptyFollowups=AlbumReserveLog(),emptyStarted=AlbumReserveLog(),emptyGate=DispatchSemaphore(value:0)
    defer { emptyGate.signal() }
    empty.suggestions=[]
    empty.automaticScoreOverride={ _ in emptyStarted.add("rank");_=emptyGate.wait(timeout:.now()+10);return emptyChoices }
    empty.playbackStartOverride={ request in
        let following=request["following_tracks"] as! [[String:Any]]
        emptyPlays.add(String(following.count));emptyFollowups.add((following[0]["ids"] as! [String])[0]);return try response(request)
    }
    empty.play(emptyAlbum)
    try wait({!emptyStarted.items.isEmpty},"empty album cache starts asynchronous fallback")
    try expect(emptyPlays.items.isEmpty && empty.playbackTrackID != nil,"an empty cache cannot invent a post-album song")
    try empty.archive.feedback(emptyChoices[0].id,"later")
    let freshExpected=try empty.archive.playbackIDs(for:emptyChoices[1].id).first!
    emptyGate.signal()
    try wait({emptyPlays.items.count==1 && empty.automaticQueue.waitingForAlbum},"async empty-cache fallback preserves a verified album continuation")
    try expect(emptyPlays.items==["1"] && emptyFollowups.items==[freshExpected],"fallback rechecks feedback changed during scoring and keeps one eligible continuation")
    empty.stopAutomaticQueue()

    let (changed,changedAlbum,changedChoices)=try fixture("changed-during-resolution"),changedPlays=AlbumReserveLog(),resolveStarted=AlbumReserveLog(),resolveGate=DispatchSemaphore(value:0)
    defer { resolveGate.signal() }
    let resolve=changed.catalogResolveOverride!
    changed.catalogResolveOverride={ requests in resolveStarted.add("resolve");_=resolveGate.wait(timeout:.now()+10);return try resolve(requests) }
    changed.playbackStartOverride={ request in changedPlays.add("play");return try response(request) }
    changed.play(changedAlbum)
    try wait({!resolveStarted.items.isEmpty},"catalog resolution begins before fresh feedback changes")
    try changed.archive.feedback(changedChoices[0].id,"later")
    resolveGate.signal()
    try wait({changed.playbackTrackID==nil},"post-resolution feedback validation completes")
    try expect(changedPlays.items.isEmpty && changed.playbackError.contains("follow-up changed"),"a song hidden during catalog lookup cannot be put in the album source playlist")

    let (cancelled,cancelAlbum,_)=try fixture("cancelled"),cancelPlays=AlbumReserveLog(),cancelStarted=AlbumReserveLog(),cancelGate=DispatchSemaphore(value:0)
    defer { cancelGate.signal() }
    cancelled.suggestions=[]
    cancelled.automaticScoreOverride={ snapshot in cancelStarted.add("rank");_=cancelGate.wait(timeout:.now()+10);return snapshot.scored(limit:100) }
    cancelled.playbackStartOverride={ request in cancelPlays.add("play");return try response(request) }
    cancelled.play(cancelAlbum)
    try wait({!cancelStarted.items.isEmpty},"cancel fixture begins empty-cache scoring")
    cancelled.stopAutomaticQueue();cancelGate.signal()
    try wait({cancelled.playbackTrackID==nil},"cancelled fallback drains")
    try expect(cancelPlays.items.isEmpty && !cancelled.automaticQueue.enabled,"Stop prevents a stale fallback from later issuing playback")
    let (alone,aloneAlbum,_)=try fixture("no-followup"),alonePlays=AlbumReserveLog()
    alone.suggestions=[]
    alone.automaticScoreOverride={ _ in [] }
    alone.playbackStartOverride={ request in
        try expect((request["following_tracks"] as? [[String:Any]])?.isEmpty==true,"no eligible song produces an empty continuation")
        alonePlays.add("play");return try response(request)
    }
    alone.play(aloneAlbum)
    try wait({alone.playbackTrackID==nil},"album without a follow-up finishes preparation")
    try expect(alonePlays.items==["play"] && alone.playbackError.isEmpty && !alone.automaticQueue.enabled,"a valid album still plays when no follow-up is eligible")
    print("PASS: album uses click-cached outside-album B/C/D while ranking blocks, source order/gate hold, empty cache revalidates feedback after scoring/resolution and Stop prevents late playback. Fake Music only.")
}
