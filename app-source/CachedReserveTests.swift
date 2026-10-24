import Foundation

private final class CachedReserveLog {
    private let lock=NSLock()
    private var values:[String]=[]
    func add(_ value:String) { lock.lock();values.append(value);lock.unlock() }
    var items:[String] { lock.lock();defer{lock.unlock()};return values }
}
@MainActor func cachedReserveTests() throws {
    func expect(_ value:Bool,_ message:String) throws { if !value { throw AppError(message:"Cached reserve test: "+message) } }
    func wait(_ condition:()->Bool,_ message:String) throws {
        let deadline=Date().addingTimeInterval(2)
        while !condition() && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
        try expect(condition(),message)
    }
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-cached-reserve-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let model=try Model(folder:folder),now=Date()
    try model.allowCollection(recordOnLaunch:false)
    let rows=(1...24).map { n -> [String:Any] in
        ["persistent_id":String(format:"%016X",n),"title":"Cached \(n)","artist":"Artist \(n)","album_artist":"Artist \(n)","album":"Album \(n)","duration":180,"play_count":20,"last_played":stamp(now.addingTimeInterval(-20*86400)),"disc_number":1,"disc_count":1,"track_number":1,"track_count":1]
    }
    try model.archive.ingestLibrary(["running":true,"tracks":rows])
    model.refreshSuggestions(background:false)
    model.menuSongBusy=true // Isolated fixture: no real Music reads.
    model.menuSample=Sample(["running":true,"state":"playing","title":"Current","persistent_id":"0000000000000001"])
    let cached=try model.suggestions.filter { song in !((try model.archive.playbackIDs(for:song.id)).contains("0000000000000001")) }
    let expected=try Array(cached.prefix(3)).map { song in (try model.archive.playbackIDs(for:song.id)).first! }
    try expect(expected.count==3,"fixture has three cached eligible songs")
    let rankGate=DispatchSemaphore(value:0),rankCalls=CachedReserveLog(),inserted=CachedReserveLog()
    defer { rankGate.signal() }
    model.automaticScoreOverride={ snapshot in
        rankCalls.add("scoring")
        _=rankGate.wait(timeout:.now()+10)
        return snapshot.scored(limit:100)
    }
    model.catalogResolveOverride={ requests in
        requests.enumerated().map { index,request in
            let pid=(request["ids"] as! [String])[0]
            return CatalogQueueSong(index:index,persistentID:pid,catalogID:String(UInt64(pid,radix:16)!+10000))
        }
    }
    model.queueAppendOverride={ request in inserted.add(request["catalog_id"] as! String);return 1 }
    model.nextForYou()
    try wait({inserted.items.count==1 && !rankCalls.items.isEmpty},"first cached song inserts while next-batch ranking is blocked")
    try wait({model.preparedAutomaticSongs.count==2 && model.playbackTrackID==nil},"remaining two cached IDs prepare while ranking is blocked")
    // Replace the visible batch: the click's reserved sequence must remain stable.
    model.suggestions=Array(model.suggestions.reversed())
    for index in 0..<2 {
        let sample=Sample(["running":true,"state":"playing","title":"Cached playing","persistent_id":expected[index]])
        model.menuSample=sample;model.observeAutomaticQueue(sample)
        try wait({inserted.items.count==index+2 && model.playbackTrackID==nil},"cached reserve consumption progresses despite blocked ranking")
        for _ in 0..<5 { model.observeAutomaticQueue(sample) }
    }
    let expectedCatalogs=expected.map{String(UInt64($0,radix:16)!+10000)}
    try expect(inserted.items==expectedCatalogs && model.automaticQueue.songs.count==2,"exact click-reserved B/C/D order and current-plus-one ledger are preserved")
    model.nextForYou()
    try expect(inserted.items.count==3,"active Next does not stack a new seed batch")
    model.stopAutomaticQueue();rankGate.signal()
    let drain=Date().addingTimeInterval(0.15)
    while Date()<drain { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
    try expect(inserted.items.count==3 && !model.automaticQueue.enabled && model.preparedAutomaticSongs.isEmpty,"stale next-batch result cannot restart stopped reserve")
    // A short cache is useful immediately; it must not wait to manufacture three choices.
    let small=try Model(folder:folder.appendingPathComponent("small")),smallLog=CachedReserveLog(),smallRanks=CachedReserveLog(),smallGate=DispatchSemaphore(value:0)
    try small.allowCollection(recordOnLaunch:false)
    defer { smallGate.signal() }
    try small.archive.ingestLibrary(["running":true,"tracks":rows])
    small.menuSongBusy=true
    let smallID=try small.archive.rows("SELECT track_id FROM track_aliases WHERE value=? AND kind='persistent'",[expected[0]]).first!["track_id"]!
    small.suggestions=[try small.archive.recommendationForTrack(smallID)!]
    small.catalogResolveOverride=model.catalogResolveOverride
    small.queueAppendOverride={ request in smallLog.add(request["catalog_id"] as! String);return 1 }
    small.automaticScoreOverride={ snapshot in smallRanks.add("rank");_=smallGate.wait(timeout:.now()+10);return snapshot.scored(limit:100) }
    small.nextForYou()
    try wait({smallLog.items.count==1 && !smallRanks.items.isEmpty},"one cached eligible song inserts without waiting to fill a three-song reserve")
    try expect(small.preparedAutomaticSongs.isEmpty,"a short cache does not invent extra prepared IDs")
    small.stopAutomaticQueue();smallGate.signal()

    let fresh=try Model(folder:folder.appendingPathComponent("fresh")),freshLog=CachedReserveLog(),freshRanks=CachedReserveLog(),freshGate=DispatchSemaphore(value:0)
    try fresh.allowCollection(recordOnLaunch:false)
    defer { freshGate.signal() }
    try fresh.archive.ingestLibrary(["running":true,"tracks":rows])
    fresh.menuSongBusy=true;fresh.menuSample=Sample(["running":true,"state":"playing","title":"Current","persistent_id":"0000000000000001"])
    let freshChoices=try expected.map { pid in try fresh.archive.recommendationForTrack(fresh.archive.rows("SELECT track_id FROM track_aliases WHERE value=? AND kind='persistent'",[pid]).first!["track_id"]!)! }
    fresh.suggestions=freshChoices
    fresh.catalogResolveOverride=model.catalogResolveOverride
    fresh.queueAppendOverride={ request in freshLog.add(request["catalog_id"] as! String);return 1 }
    fresh.automaticScoreOverride={ snapshot in freshRanks.add("rank");_=freshGate.wait(timeout:.now()+10);return snapshot.scored(limit:100) }
    fresh.nextForYou()
    try wait({freshLog.items.count==1 && fresh.preparedAutomaticSongs.count==2 && !freshRanks.items.isEmpty && fresh.playbackTrackID==nil},"feedback fixture prepares its cached reserve")
    try fresh.archive.feedback(freshChoices[1].id,"later")
    let playing=Sample(["running":true,"state":"playing","title":"Cached B","persistent_id":expected[0]])
    fresh.menuSample=playing;fresh.observeAutomaticQueue(playing)
    try wait({freshLog.items.count==2 && fresh.playbackTrackID==nil},"fresh feedback skips a hidden reserved C without waiting for ranking")
    try expect(freshLog.items.last==expectedCatalogs[2],"only the remaining eligible reserved D is submitted")
    fresh.stopAutomaticQueue();freshGate.signal()

    print("PASS: click-cached B/C/D resolve and insert while next-batch ranking is blocked; click order, short-cache immediacy, fresh feedback, one pending song, duplicate/Next guards and cancellation hold. No Music calls.")
}
