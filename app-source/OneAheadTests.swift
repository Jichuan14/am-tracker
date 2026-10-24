import Foundation

private final class QueueTestLog {
    private let lock=NSLock()
    private var values:[String]=[]
    func append(_ value:String) { lock.lock();values.append(value);lock.unlock() }
    var snapshot:[String] { lock.lock();defer{lock.unlock()};return values }
}
@MainActor func oneAheadTests() throws {
    func expect(_ value:Bool,_ message:String) throws { if !value { throw AppError(message:"One-ahead test: "+message) } }
    func wait(_ condition:()->Bool,_ message:String) throws {
        let deadline=Date().addingTimeInterval(5)
        while !condition() && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
        try expect(condition(),message)
    }
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-one-ahead-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    func fixture(_ name:String) throws -> Model {
        let model=try Model(folder:root.appendingPathComponent(name))
        try model.allowCollection(recordOnLaunch:false)
        for n in 1...36 {
            let pid=String(format:"%016X",n)
            var song=ImportedSong(title:"Prepared "+pid);song.artist="Artist \(n)";song.album="Prepared album";song.persistentID=pid;song.duration=180
            let id=try model.archive.resolve(song);try model.archive.feedback(id,"like")
        }
        model.menuSongBusy=true // Never query or control real Music in these tests.
        model.menuSample=Sample(["running":true,"state":"playing","title":"Current","persistent_id":"0000000000000001"])
        return model
    }
    func details(_ pid:String)->QueueSongMetadata { QueueSongMetadata(title:"Prepared "+pid,artist:"Fixture artist",album:"Prepared album",duration:180) }
    func resolve(_ requests:[[String:Any]])->[CatalogQueueSong] {
        requests.enumerated().map { index,request in
            let pid=(request["ids"] as! [String])[0]
            return CatalogQueueSong(index:index,persistentID:pid,catalogID:String((UInt64(pid,radix:16) ?? 0)+10000),metadata:details(pid))
        }
    }
    func sample(_ pid:String,_ runtimeID:String)->Sample {
        let d=details(pid)
        return Sample(["running":true,"state":"playing","persistent_id":runtimeID,"track_class":"urlTrack","title":d.title,"artist":d.artist,"album":d.album,"duration":d.duration])
    }
    let model=try fixture("prepared"),log=QueueTestLog(),calls=QueueTestLog()
    let resolverGate=DispatchSemaphore(value:0),ackGate=DispatchSemaphore(value:0)
    defer { resolverGate.signal();ackGate.signal() }
    model.catalogResolveOverride={ requests in
        calls.append("resolve")
        if calls.snapshot.count==4 { _=resolverGate.wait(timeout:.now()+5) }
        return resolve(requests)
    }
    model.queueAppendOverride={ request in
        log.append(request["catalog_id"] as! String)
        if log.snapshot.count==1 { _=ackGate.wait(timeout:.now()+5) }
        return 1
    }
    model.nextForYou()
    try wait({log.snapshot.count==1 && model.preparedAutomaticSongs.count==2 && !model.automaticPreparationBusy},"future IDs prepare progressively while the first native ACK is blocked")
    try expect(model.playedForYouIDs.isEmpty,"neither preparation nor a pending acknowledgment creates playback cooldown")
    let first=String(format:"%016X",UInt64(log.snapshot[0])!-10000)
    let second=model.preparedAutomaticSongs[0]
    let firstSample=sample(first,"F000000000000001")
    model.menuSample=firstSample
    for _ in 0..<10 { model.observeAutomaticQueue(firstSample) }
    model.observeAutomaticQueue(Sample(["running":true,"state":"paused","persistent_id":"F000000000000001"]))
    try expect(log.snapshot.count==1,"delayed ACK observations cannot start concurrent insertions")
    ackGate.signal()
    try wait({log.snapshot.count==2 && model.playbackTrackID==nil && model.automaticPreparationBusy && calls.snapshot.count==4},"deferred playing observation submits cached C once after B is registered, even while future resolution blocks")
    try expect(log.snapshot.last==second.entry.catalogID && model.playedForYouIDs.count==2,"latest valid playback is reconciled after the delayed ACK")
    for _ in 0..<10 { model.observeAutomaticQueue(firstSample) }
    try expect(log.snapshot.count==2 && model.automaticQueue.pendingReplacements==0,"repeated samples cannot add another song")
    let third=model.preparedAutomaticSongs[0]
    let secondSample=sample(second.entry.persistentID,"F000000000000002")
    model.menuSample=secondSample;model.observeAutomaticQueue(secondSample)
    try wait({log.snapshot.count==3 && model.playbackTrackID==nil},"next short skip submits one cached successor while resolver remains blocked")
    try expect(log.snapshot.last==third.entry.catalogID && model.automaticQueue.songs.count==2,"only current song and one future song are in the owned queue ledger")
    resolverGate.signal()
    try wait({!model.automaticPreparationBusy && model.preparedAutomaticSongs.count==2},"local look-ahead cache is replenished")
    model.nextForYou()
    try expect(log.snapshot.count==3,"repeated Next for you cannot stack extra pending songs")
    let rejected=model.preparedAutomaticSongs[0]
    model.rate(rejected.recommendation.id,"later")
    let thirdSample=sample(third.entry.persistentID,"F000000000000003")
    model.menuSample=thirdSample;model.observeAutomaticQueue(thirdSample)
    try wait({log.snapshot.count==4 && model.playbackTrackID==nil && !model.automaticPreparationBusy},"one eligible successor replaces a newly hidden prepared song")
    try expect(log.snapshot.last != rejected.entry.catalogID,"new feedback is respected before sending a prepared song")
    try expect(model.playedForYouIDs.count==4 && (try model.archive.rows("SELECT * FROM sessions")).isEmpty,"only acknowledged submissions create cooldowns and preparation invents no listening history")
    let validationTimes=model.queueLatency.snapshot.filter{$0["phase"] as? String=="cache_hit_validated"}.compactMap{$0["duration_ms"] as? Double}
    if let low=validationTimes.min(),let high=validationTimes.max() { print(String(format:"MOCK timing: %d prepared validations %.2f–%.2f ms (36-track fixture; no Music latency measured).",validationTimes.count,low,high)) }
    model.stopAutomaticQueue()

    let album=try fixture("album"),albumLog=QueueTestLog()
    album.catalogResolveOverride=resolve
    album.queueAppendOverride={ request in albumLog.append(request["catalog_id"] as! String);return 1 }
    let choices=try album.archive.automaticQueueSongs(excluding:[],currentPersistentID:nil,limit:3)
    let entries=resolve(try choices.map{try album.archive.queueRequest(for:$0.id)})
    let prepared=zip(choices,entries).map{PreparedAutomaticSong(recommendation:$0.0,entry:$0.1)}
    try album.completeAutomaticQueue([prepared[0].recommendation],addedCount:1)
    let albumID="A000000000000001"
    album.startAlbumAutomaticQueue(first:prepared[0],following:Array(prepared.dropFirst()),albumIDs:[albumID])
    album.observeAutomaticQueue(Sample(["running":true,"state":"playing","persistent_id":albumID,"title":"Album track"]))
    try expect(albumLog.snapshot.isEmpty && album.automaticQueue.waitingForAlbum,"no native insertion can jump ahead of album playback")
    let followup=sample(prepared[0].entry.persistentID,"F000000000000010")
    album.menuSample=followup;album.observeAutomaticQueue(followup)
    try wait({albumLog.snapshot.count==1 && album.playbackTrackID==nil && !album.automaticPreparationBusy},"the first album follow-up starts the one-ahead chain")
    try expect(albumLog.snapshot==[prepared[1].entry.catalogID],"album continuation uses its already-prepared next ID")
    album.stopAutomaticQueue()

    let stopped=try fixture("cancelled"),stoppedLog=QueueTestLog(),started=QueueTestLog(),stopGate=DispatchSemaphore(value:0)
    defer { stopGate.signal() }
    stopped.catalogResolveOverride={ requests in started.append("started");_=stopGate.wait(timeout:.now()+5);return resolve(requests) }
    stopped.queueAppendOverride={ request in stoppedLog.append(request["catalog_id"] as! String);return 1 }
    stopped.nextForYou()
    try wait({!started.snapshot.isEmpty},"cancellation fixture begins preparation")
    stopped.stopAutomaticQueue();stopGate.signal()
    let drain=Date().addingTimeInterval(0.1)
    while Date()<drain { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
    try expect(stoppedLog.snapshot.isEmpty && stopped.preparedAutomaticSongs.isEmpty && !stopped.automaticQueue.enabled,"stale preparation cannot restart or queue after Stop")
    let failed=try fixture("failed-ack"),failedLog=QueueTestLog()
    failed.catalogResolveOverride=resolve
    failed.queueAppendOverride={ request in failedLog.append("attempt");throw AppError(message:"Uncertain ACK") }
    failed.nextForYou()
    try wait({!failed.automaticQueue.enabled && failed.playbackTrackID==nil},"failed native ACK stops the chain")
    try expect(failedLog.snapshot.count==1 && failed.playedForYouIDs.isEmpty && failed.preparedAutomaticSongs.isEmpty,"uncertain ACK creates no cooldown and is never retried")

    let replaced=try fixture("replaced-preparation"),replaceCalls=QueueTestLog(),replaceLog=QueueTestLog()
    let oldGate=DispatchSemaphore(value:0),newGate=DispatchSemaphore(value:0)
    defer { oldGate.signal();newGate.signal() }
    replaced.catalogResolveOverride={ requests in
        replaceCalls.append("resolve")
        if replaceCalls.snapshot.count==1 { _=oldGate.wait(timeout:.now()+5) }
        if replaceCalls.snapshot.count==2 { _=newGate.wait(timeout:.now()+5) }
        return resolve(requests)
    }
    replaced.queueAppendOverride={_ in replaceLog.append("insert");return 1}
    replaced.nextForYou()
    try wait({replaceCalls.snapshot.count==1},"old preparation begins")
    replaced.stopAutomaticQueue();replaced.nextForYou();oldGate.signal()
    try wait({replaceCalls.snapshot.count==2},"replacement chain owns the new preparation request")
    let settle=Date().addingTimeInterval(0.05)
    while Date()<settle { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
    try expect(replaced.automaticPreparationBusy && replaced.preparedAutomaticSongs.isEmpty && replaceLog.snapshot.isEmpty,"old callback cannot clear new busy state or insert an old selection")
    newGate.signal()
    try wait({replaceLog.snapshot.count==1 && replaced.playbackTrackID==nil && !replaced.automaticPreparationBusy},"new chain finishes after old preparation is discarded")
    replaced.stopAutomaticQueue()

    let progressive=try fixture("progressive"),progressCalls=QueueTestLog(),progressLog=QueueTestLog(),progressGate=DispatchSemaphore(value:0)
    defer { progressGate.signal() }
    progressive.catalogResolveOverride={ requests in
        progressCalls.append("resolve")
        if progressCalls.snapshot.count==2 { _=progressGate.wait(timeout:.now()+5) }
        return resolve(requests)
    }
    progressive.queueAppendOverride={_ in progressLog.append("insert");return 1}
    progressive.nextForYou()
    try wait({progressLog.snapshot.count==1 && progressCalls.snapshot.count==2 && progressive.playbackTrackID==nil},"first resolved B submits before the following C resolution completes")
    try expect(progressive.preparedAutomaticSongs.isEmpty && progressive.automaticPreparationBusy,"a cold start never waits for two mappings before its first insertion")
    progressGate.signal()
    try wait({!progressive.automaticPreparationBusy && progressive.preparedAutomaticSongs.count==2},"progressive future cache fills")
    // Force a fresh ranking job and block it, while a prepared next ID remains usable.
    let scoreGate=DispatchSemaphore(value:0),scoreCalls=QueueTestLog()
    defer { scoreGate.signal() }
    progressive.automaticCandidates=[]
    progressive.automaticScoreOverride={ snapshot in scoreCalls.append("score");_=scoreGate.wait(timeout:.now()+5);return snapshot.scored(limit:100) }
    let b=progressive.automaticQueue.songs.last!.first!,c=progressive.preparedAutomaticSongs[0]
    let bSample=sample(b,"E000000000000001")
    progressive.menuSample=bSample;progressive.observeAutomaticQueue(bSample)
    try wait({progressLog.snapshot.count==2 && progressive.playbackTrackID==nil && scoreCalls.snapshot.count==1},"fresh scoring runs separately from insertion")
    let cSample=sample(c.entry.persistentID,"E000000000000002")
    progressive.menuSample=cSample;progressive.observeAutomaticQueue(cSample)
    try wait({progressLog.snapshot.count==3 && progressive.playbackTrackID==nil},"warm cached skip bypasses blocked recommendation scoring")
    scoreGate.signal()
    try wait({!progressive.automaticPreparationBusy},"scoring job drains")
    progressive.stopAutomaticQueue()

    let late=try fixture("stopped-ack"),lateLog=QueueTestLog(),lateGate=DispatchSemaphore(value:0)
    defer { lateGate.signal() }
    late.catalogResolveOverride=resolve
    late.queueAppendOverride={_ in lateLog.append("insert");_=lateGate.wait(timeout:.now()+5);return 1}
    late.nextForYou()
    try wait({lateLog.snapshot.count==1},"late ACK begins")
    late.stopAutomaticQueue();lateGate.signal()
    try wait({late.playbackTrackID==nil},"stopped ACK releases only its own insertion slot")
    try expect(!late.automaticQueue.enabled && late.preparedAutomaticSongs.isEmpty && late.playedForYouIDs.isEmpty && lateLog.snapshot.count==1,"late accepted callback cannot restart a stopped chain")

    let eligibility=try fixture("eligibility")
    let choice=try eligibility.archive.automaticQueueSongs(excluding:[],currentPersistentID:nil,limit:1)[0]
    let request=try eligibility.archive.queueRequest(for:choice.id),entry=resolve([request])[0]
    let checked=PreparedAutomaticSong(recommendation:choice,entry:entry)
    func eligible()->Bool { (try? eligibility.archive.automaticSongIsEligible(checked,excluding:[],currentPersistentID:nil,knownIDs:[])) ?? false }
    try expect(eligible(),"an unchanged prepared selection remains eligible")
    try eligibility.archive.rememberForYouSelections([choice.id])
    try expect(!eligible(),"fresh selection cooldown blocks a cached song")
    try eligibility.archive.meta("for_you_playback_cooldowns","")
    try eligibility.archive.saveAlbumMetadata(["album_artist":"Album artist","album":"Album title","track_number":1,"track_count":1],id:choice.id)
    let albumKey=albumIdentity(artist:"Album artist",title:"Album title")!
    try eligibility.archive.feedback(albumKey,"less")
    try expect(!eligible(),"fresh album feedback blocks a cached component song")
    try eligibility.archive.undoRecommendationFeedback()
    try expect(eligible(),"unblocking the album preserves the prepared choice")
    try eligibility.archive.feedback(choice.id,"reset")
    try eligibility.archive.feedback(albumKey,"mode_tracks")
    try expect(eligible(),"a prepared unliked song stays eligible in individual-song mode")
    try eligibility.archive.feedback(albumKey,"mode_album")
    try expect(!eligible(),"new Prefer whole album feedback invalidates a cached component without independent evidence")
    try eligibility.archive.feedback(choice.id,"like")
    try expect(eligible(),"an explicit song Like preserves the whole-album independent exception")
    try eligibility.archive.feedback(choice.id,"reset")
    func independentListen(_ date:Date) throws {
        try eligibility.archive.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,last_listening_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?,?)",
            [entry.persistentID,choice.title,"Album artist","Album title",stamp(date),stamp(date.addingTimeInterval(180)),stamp(date.addingTimeInterval(180)),stamp(date.addingTimeInterval(180)),180,180])
    }
    let independentStart=Date().addingTimeInterval(-5*86400)
    for offset in [0.0,190.0,380.0] { try independentListen(independentStart.addingTimeInterval(offset)) }
    try eligibility.archive.syncRecordingsAndLibrary(includeLibrary:false)
    try expect(!eligible(),"three standalone plays in only one period do not bypass whole-album mode")
    try independentListen(independentStart.addingTimeInterval(86400))
    try eligibility.archive.syncRecordingsAndLibrary(includeLibrary:false)
    try expect(eligible(),"three or more standalone plays across two independent periods preserve the prepared component")
    try eligibility.archive.exec("DELETE FROM track_aliases WHERE track_id=? AND kind='persistent'",[choice.id])
    try expect(!eligible(),"removed exact persistent identity cannot use a stale prepared mapping")

    let reads=try fixture("coalesced-read"),readCalls=QueueTestLog(),readGate=DispatchSemaphore(value:0)
    defer { readGate.signal() }
    reads.menuSongBusy=false
    reads.playbackReadOverride={
        readCalls.append("read")
        let first=readCalls.snapshot.count==1
        if first { _=readGate.wait(timeout:.now()+5) }
        return ["running":true,"state":"playing","title":first ? "Old" : "New","persistent_id":first ? "0000000000000001" : "0000000000000002"]
    }
    reads.refreshMenuSong(notification:true)
    try wait({readCalls.snapshot.count==1},"first read begins")
    for _ in 0..<20 { reads.refreshMenuSong(notification:true) }
    readGate.signal()
    try wait({readCalls.snapshot.count==2 && !reads.menuSongBusy},"busy playback notifications produce one immediate trailing read")
    try expect(reads.menuSample?.title=="New" && !reads.menuSongPending,"coalescing preserves the newest complete observation")
    try expect(reads.queueLatency.snapshot.contains{$0["phase"] as? String=="read_coalesced"},"bounded diagnostics record coalescing")
    for _ in 0..<300 { reads.queueLatency.record("bounded",epoch:0) }
    try expect(reads.queueLatency.snapshot.count==256 && reads.queueLatency.snapshot.allSatisfy{($0["uptime_ms"] as? Double ?? -1)>=0},"diagnostics remain bounded and use a monotonic clock")

    // Snapshot scoring is value-only, deterministic and safe while archive state advances.
    let snapshot=try reads.archive.recommendationSnapshot()
    let frozen=snapshot.scored(limit:100)
    try reads.archive.feedback(frozen[0].id,"less")
    try expect(snapshot.scored(limit:100).map{$0.id}==frozen.map{$0.id},"scoring reads captured values rather than live SQLite")
    let current=try reads.archive.recommendations(limit:100)
    try expect(!current.contains{$0.id==frozen[0].id},"a fresh snapshot observes later feedback")

    print("PASS: progressive preparation during ACK, cached skips during blocked scoring/resolution, delayed-ACK reconciliation, duplicate guards, fresh eligibility, album handoff, stale tokens, stopped/failed ACK, coalesced reads and bounded timing. No Music calls.")
}
