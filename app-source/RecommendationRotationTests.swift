import Foundation

@MainActor func recommendationRotationTests() throws {
    func expect(_ condition:Bool,_ message:String) throws {
        guard condition else { throw AppError(message:"Rotation test: "+message) }
    }
    let now=Date(timeIntervalSince1970:1_790_000_000)
    func library(_ count:Int) -> [[String:Any]] {
        (1...count).map { n in
            ["persistent_id":String(format:"%016X",n),"title":"Rotation \(n)","artist":"Artist \(n)","album_artist":"Artist \(n)",
             "album":"Album \(n)","genre":"Pop","duration":180,"play_count":20,
             "last_played":stamp(now.addingTimeInterval(-20*86400)),"disc_number":1,"disc_count":1,"track_number":1,"track_count":1]
        }
    }
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-rotation-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let db=try Archive(folder:folder)
    try db.ingestLibrary(["running":true,"tracks":library(40)])
    func batch(_ db:Archive,intent:RecommendationRefreshIntent = .advance,at date:Date?=nil,limit:Int=10) throws -> RecommendationRotationResult {
        let snapshot=try db.forYouSnapshot(now:date ?? now,intent:intent)
        let result=snapshot.forYouResult(limit:limit)
        try expect(recommendationFingerprint(result.items)==recommendationFingerprint(snapshot.forYouResult(limit:limit).items),"same snapshot/state is deterministic")
        try db.commitForYouResult(result,at:date ?? now)
        return result
    }
    var seen=Set<String>(),batches:[[String]]=[]
    for generation in 1...4 {
        let result=try batch(db),ids=result.items.map{$0.id}
        try expect(ids.count==10 && Set(ids).isDisjoint(with:seen),"four successive ten-song batches exhaust 40 songs before repeating")
        try expect(result.state.generation==generation,"only explicit advances increment the generation")
        seen.formUnion(ids);batches.append(ids)
    }
    let reopened=try Archive(folder:folder)
    let restored=try batch(reopened,intent:.revalidate)
    try expect(restored.items.map{$0.id}==batches[3] && restored.state.generation==4,"restart restores valid current order")
    let oldState=try reopened.value(Archive.recommendationRotationKey),auditCount=try reopened.rows("SELECT * FROM recommendation_batches").count
    for _ in 0..<3 { _=try reopened.recommendations();_=try reopened.recommendationSnapshot().scored() }
    _=try batch(reopened,intent:.revalidate)
    try expect(try reopened.value(Archive.recommendationRotationKey)==oldState && reopened.rows("SELECT * FROM recommendation_batches").count==auditCount,"passive render and hidden scoring have no exposure/audit effect")
    let fifth=try batch(reopened)
    try expect(fifth.items.map{$0.id}==batches[0],"next refresh after restart respects three persisted generations")
    let blocked=fifth.items[3],otherIDs=fifth.items.filter{$0.id != blocked.id}.map{$0.id}
    try reopened.feedback(blocked.id,"later",at:now)
    let refill=try batch(reopened,intent:.revalidate)
    try expect(refill.state.generation==5 && refill.items.prefix(9).map{$0.id}==otherIDs && !refill.items.contains{$0.id==blocked.id},"feedback removes only an ineligible item and fills the vacancy")
    try expect(refill.state.generations.last!.exposures.count==11 && refill.state.generations.last!.exposures.contains{$0.id==blocked.id},"original and replacement are both exposed in the same generation")
    let refillIDs=refill.items.map{$0.id}
    try reopened.feedback(refill.items[0].id,"like",at:now)
    try expect(try batch(reopened,intent:.revalidate).items.map{$0.id}==refillIDs,"Like changes relevance without reshuffling retained entries")
    try reopened.undoRecommendationFeedback()
    try expect(try batch(reopened,intent:.revalidate).items.map{$0.id}==refillIDs,"Undo revalidates without reshuffling")
    let playing=refill.items[1]
    try reopened.rememberForYouPlayback(playing,at:now)
    let afterPlayback=try batch(reopened,intent:.revalidate)
    try expect(!afterPlayback.items.contains{$0.id==playing.id} && afterPlayback.state.generation==5,"confirmed playback removes a current item without advancing")
    try expect(afterPlayback.items.filter{refillIDs.contains($0.id)}.map{$0.id}==refillIDs.filter{$0 != playing.id},"refill retains survivor order")
    let expired=try reopened.forYouSnapshot(now:now.addingTimeInterval(7*86400+1),intent:.advance)
    try expect(recommendationFingerprint(expired.forYouResult().items)==recommendationFingerprint(try reopened.recommendationSnapshot(now:expired.now).scored()),"exposures expire after seven days")
    try expect(try reopened.forYouSnapshot(now:now).forYouResult(limit:0).items.isEmpty,"zero limit")

    // A current generation can outlive the exposure window. Only a new replacement renews exposure.
    let lateFolder=folder.appendingPathComponent("long-lived")
    let late=try Archive(folder:lateFolder)
    try late.ingestLibrary(["running":true,"tracks":library(40)])
    let original=try batch(late),later=now.addingTimeInterval(8*86400)
    try late.feedback(original.items[0].id,"less",at:later)
    let lateRefill=try batch(late,intent:.revalidate,at:later)
    let replacement=lateRefill.items.first{item in !original.items.contains{$0.id==item.id}}!
    let lateContext=try late.forYouSnapshot(now:later,intent:.advance).rotation!
    try expect(lateRefill.state.generation==1 && lateContext.priority(replacement,now:later).generation==1,"replacement gets insertion time in an expired generation")
    try expect(lateContext.priority(original.items[1],now:later).generation==0,"retained entries do not renew expired exposure")

    _=try batch(late,intent:.revalidate,at:later.addingTimeInterval(1))
    try expect(try late.forYouSnapshot(now:later.addingTimeInterval(1),intent:.advance).rotation!.priority(original.items[1],now:later).generation==0,"revalidating after expiry pruning never renews retained entries")
    try expect(try !batch(late,at:later).items.contains{$0.id==replacement.id},"next explicit refresh avoids a newly inserted replacement in an old generation")
    let reentryFolder=folder.appendingPathComponent("reentry"),reentry=try Archive(folder:reentryFolder)
    try reentry.ingestLibrary(["running":true,"tracks":library(11)])
    let firstEntry=try batch(reentry),reappearing=firstEntry.items[0]
    try reentry.feedback(reappearing.id,"later",at:now)
    _=try batch(reentry,intent:.revalidate)
    // Remove a different entry after the old cooldown/exposure expired, creating a vacancy for A.
    try reentry.feedback(firstEntry.items[1].id,"less",at:later)
    let reentered=try batch(reentry,intent:.revalidate,at:later)
    try expect(reentered.items.contains{$0.id==reappearing.id} && reentered.state.generations.last!.exposures.first{$0.id==reappearing.id}?.at==later.timeIntervalSince1970,"removed ID re-entering an old generation gets a new timestamp")
    // Add spare independent songs so the next batch has enough unexposed choices to avoid A.
    try reentry.ingestLibrary(["running":true,"tracks":library(25)])
    try expect(try !batch(reentry,at:later).items.contains{$0.id==reappearing.id},"next explicit batch avoids an ID just re-exposed in its original generation")

    // Whole-album feedback eligibility is stricter only for the visible surface.
    let albumFolder=folder.appendingPathComponent("album-feedback"),albumDB=try Archive(folder:albumFolder)
    var albumLibrary=library(20)
    for i in 0..<3 {
        albumLibrary[i]["album_artist"]="Album artist";albumLibrary[i]["album"]="Complete release"
        albumLibrary[i]["track_number"]=i+1;albumLibrary[i]["track_count"]=3
    }
    try albumDB.ingestLibrary(["running":true,"tracks":albumLibrary])
    let albumID=albumIdentity(artist:"Album artist",title:"Complete release")!
    try albumDB.feedback(albumID,"mode_album",at:now)
    try albumDB.feedback(albumID,"like",at:now)
    let albumBatch=try batch(albumDB)
    try expect(albumBatch.items.contains{$0.id==albumID},"playable album fixture starts in the current batch")
    let blockedMember=try albumDB.albumCollections().first{$0.id==albumID}!.tracks[0].id
    try albumDB.feedback(blockedMember,"later",at:now)
    let hiddenAlbum=try batch(albumDB,intent:.revalidate)
    try expect(hiddenAlbum.state.generation==1 && hiddenAlbum.items.count==10 && !hiddenAlbum.items.contains{$0.id==albumID},"member Not now removes and refills current album in the same generation")
    try expect(try albumDB.recommendations(now:now,limit:100).contains{$0.id==albumID && $0.playbackIssue != nil},"generic diagnostics preserve blocked album metadata")
    try albumDB.undoRecommendationFeedback()
    try albumDB.feedback(blockedMember,"less",at:now)
    try expect(try !batch(albumDB,intent:.revalidate).items.contains{$0.id==albumID},"member Less also makes whole album ineligible")

    let libraryCurrent=hiddenAlbum.items[0],libraryBefore=hiddenAlbum.items.map{$0.id}
    let libraryPID=try albumDB.playbackIDs(for:libraryCurrent.id).first!
    try albumDB.exec("UPDATE library_tracks SET last_played=? WHERE persistent_id=?",[stamp(now),libraryPID])
    let libraryRefill=try batch(albumDB,intent:.revalidate)
    try expect(libraryRefill.state.generation==1 && !libraryRefill.items.contains{$0.id==libraryCurrent.id} && libraryRefill.items.prefix(9).map{$0.id}==libraryBefore.filter{$0 != libraryCurrent.id},"updated library playback metadata invalidates one entry and preserves the remaining order")

    // Exact fresh-before-quota and least-recent-exposure oracles, independent of scoring.
    func song(_ id:String,score:Double=1,bucket:String="Rediscover",album:String?=nil) -> Recommendation {
        Recommendation(id:id,title:id,artist:id,album:album ?? "",catalogID:"",reason:"",score:score,bucket:bucket,kind:.song,albumID:album,trackIDs:[id],playbackIssue:nil)
    }
    let a=song("a",score:100),b=song("b",score:20),c=song("c",score:0.1,bucket:"Explore your library"),d=song("d")
    let state=RecommendationRotationState(generation:3,orderedIDs:[a.id],generations:[
        RecommendationGeneration(number:1,createdAt:now.timeIntervalSince1970-30,exposures:[RecommendationExposure(b,at:now.addingTimeInterval(-30))]),
        RecommendationGeneration(number:2,createdAt:now.timeIntervalSince1970-20,exposures:[RecommendationExposure(d,at:now.addingTimeInterval(-20))]),
        RecommendationGeneration(number:3,createdAt:now.timeIntervalSince1970-10,exposures:[RecommendationExposure(a,at:now.addingTimeInterval(-10)),RecommendationExposure(b,at:now.addingTimeInterval(-5))])])
    let context=RecommendationRotationContext(state:state,intent:.advance,revision:"")
    let scarce=selectRecommendations([a,b,c,d],vectors:[:],limit:10,rotation:context,now:now)
    try expect(scarce.map{$0.id}==["c","d","a","b"],"fresh beats bucket quotas; scarcity sorts by oldest most-recent exposure including replacements")
    let nonchronological=RecommendationRotationState(generation:3,orderedIDs:[d.id],generations:[
        RecommendationGeneration(number:1,createdAt:now.timeIntervalSince1970-30,exposures:[RecommendationExposure(a,at:now.addingTimeInterval(-1))]),
        RecommendationGeneration(number:2,createdAt:now.timeIntervalSince1970-20,exposures:[RecommendationExposure(b,at:now.addingTimeInterval(-20))]),
        RecommendationGeneration(number:3,createdAt:now.timeIntervalSince1970-10,exposures:[RecommendationExposure(d,at:now.addingTimeInterval(-10))])])
    let reordered=RecommendationRotationContext(state:nonchronological,intent:.advance,revision:"")
    try expect(selectRecommendations([a,b,c,d],vectors:[:],limit:10,rotation:reordered,now:now).map{$0.id}==["c","b","d","a"],"actual latest exposure timestamp precedes generation ordering")
    var sameTime=nonchronological
    sameTime.generations=nonchronological.generations.enumerated().map{offset,g in
        RecommendationGeneration(number:g.number,createdAt:now.timeIntervalSince1970,exposures:[RecommendationExposure([a,b,d][offset],at:now)])
    }
    try expect(selectRecommendations([a,b,c,d],vectors:[:],limit:10,rotation:RecommendationRotationContext(state:sameTime,intent:.advance,revision:""),now:now).map{$0.id}==["c","a","b","d"],"fixed-clock equal exposures use generation as deterministic tie-break")
    try expect(selectRecommendations([],vectors:[:],limit:10,rotation:context,now:now).isEmpty,"empty eligible pool")
    try expect(selectRecommendations([a],vectors:[:],limit:-1,rotation:context,now:now).isEmpty,"negative limit")
    let sibling=song("sibling",album:"release-A"),member=song("member",album:"release-A")
    let album=Recommendation(id:"release-A",title:"Album",artist:"Artist",album:"Album",catalogID:"",reason:"",score:1,bucket:"Rediscover",kind:.album,albumID:"release-A",trackIDs:[member.id,sibling.id],playbackIssue:nil)
    let otherRelease=Recommendation(id:"release-B",title:"Album",artist:"Artist",album:"Album",catalogID:"",reason:"",score:1,bucket:"Rediscover",kind:.album,albumID:"release-B",trackIDs:["other-member"],playbackIssue:nil)
    try expect(RecommendationExposure(album,at:now).overlaps(member) && RecommendationExposure(member,at:now).overlaps(album),"album/member exposure is symmetric")
    try expect(!RecommendationExposure(member,at:now).overlaps(sibling) && !RecommendationExposure(album,at:now).overlaps(otherRelease),"sibling songs and separate releases do not share exposure")
    let together=selectRecommendations([album,member,sibling,otherRelease],vectors:[:],limit:10,rotation:context,now:now)
    try expect(!(together.contains{$0.id==album.id} && together.contains{$0.id==member.id || $0.id==sibling.id}),"album/member within-batch conflict survives exposure tiers")
    // Alias reuse goes through music_tracks.id; no exposure identity uses a persistent alias.
    let canonical=fifth.items[0].id
    try reopened.exec("INSERT INTO track_aliases(kind,value,track_id) VALUES ('catalog','999991',?)",[canonical])
    var aliased=ImportedSong(title:fifth.items[0].title);aliased.catalogID="999991"
    try expect(try reopened.resolve(aliased)==canonical && fifth.state.generations.last!.exposures.contains{$0.id==canonical},"catalog aliases keep the canonical exposure identity")

    // Transaction failure must roll back state even after its metadata write succeeded.
    let beforeFailure=try reopened.value(Archive.recommendationRotationKey)
    let failed=try reopened.forYouSnapshot(now:now,intent:.advance).forYouResult()
    try reopened.exec("CREATE TRIGGER fail_rotation_audit BEFORE INSERT ON recommendation_batches BEGIN SELECT RAISE(ABORT,'injected audit failure'); END")
    var rejected=false
    do { try reopened.commitForYouResult(failed,at:now) } catch { rejected=true }
    try expect(rejected && (try reopened.value(Archive.recommendationRotationKey))==beforeFailure,"failed audit atomically rolls back rotation")
    try reopened.exec("DROP TRIGGER fail_rotation_audit")
    _=try batch(reopened)
    rejected=false
    do { try reopened.commitForYouResult(failed,at:now) } catch { rejected=true }
    try expect(rejected,"superseded snapshot cannot commit")

    // Exercise the actual main-owner publish gate, timer path and sticky advance intent.
    let modelFolder=FileManager.default.temporaryDirectory.appendingPathComponent("am-track-rotation-model-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:modelFolder) }
    let model=try Model(folder:modelFolder)
    try model.archive.ingestLibrary(["running":true,"tracks":library(40)])
    model.refreshSuggestions(background:false)
    let visible=model.suggestions.map{$0.id},modelState=try model.archive.value(Archive.recommendationRotationKey)
    let stale=try model.archive.forYouSnapshot(intent:.advance).forYouResult()
    try model.acceptSuggestions(stale,request:model.suggestionRequest-1,at:Date())
    try expect(model.suggestions.map{$0.id}==visible && (try model.archive.value(Archive.recommendationRotationKey))==modelState,"stale async result neither publishes nor consumes exposure")
    try model.archive.exec("CREATE TRIGGER fail_rotation_state BEFORE INSERT ON metadata WHEN NEW.key='for_you_rotation_v1' BEGIN SELECT RAISE(ABORT,'injected state failure'); END")
    model.refreshSuggestions(background:false,intent:.advance)
    try expect(!model.error.isEmpty && model.suggestions.map{$0.id}==visible && (try model.archive.value(Archive.recommendationRotationKey))==modelState,"persistence failure keeps prior visible batch and state coherent")
    try model.archive.exec("DROP TRIGGER fail_rotation_state")
    model.refreshSuggestions(background:false)
    let recovered=try model.archive.forYouSnapshot()
    try expect(recovered.rotation!.state.generation==2 && Set(visible).isDisjoint(with:Set(model.suggestions.map{$0.id})),"pending explicit Refresh survives revalidation and retries after failure")
    let beforeTimer=model.suggestions.map{$0.id},generationBeforeTimer=recovered.rotation!.state.generation
    var timerCompleted=false
    model.onChange={timerCompleted=true}
    model.nextRecommendations = .distantPast;model.reload();timerCompleted=false
    let deadline=Date().addingTimeInterval(5)
    while !timerCompleted && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
    try expect(timerCompleted && model.suggestions.map{$0.id}==beforeTimer && (try model.archive.forYouSnapshot().rotation!.state.generation)==generationBeforeTimer,"timer revalidation preserves generation and visible order")
    print("PASS: persistent For you rotation, fresh/oldest exposure tiers, canonical album/member identities, refill/restart/expiry, stale-result and atomic-failure gates.")
}
