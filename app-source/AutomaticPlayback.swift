import Foundation

struct PreparedAutomaticSong {
    let recommendation:Recommendation
    let entry:CatalogQueueSong
}
struct AutomaticCandidate {
    let recommendation:Recommendation
    let request:[String:Any]
}
struct AutomaticCandidateSnapshot {
    let ranking:RecommendationSnapshot
    let requests:[String:[String:Any]]
    func candidates(excluding:Set<String>,persistentIDs:Set<String>,score:((RecommendationSnapshot)->[Recommendation])?=nil) -> [AutomaticCandidate] {
        (score?(ranking) ?? ranking.scored(limit:100)).compactMap { song in
            guard song.kind == .song,song.playbackIssue==nil,!excluding.contains(song.id),
                  let request=requests[song.id],let ids=request["ids"] as? [String],!ids.isEmpty,
                  Set(ids).isDisjoint(with:persistentIDs) else { return nil }
            return AutomaticCandidate(recommendation:song,request:request)
        }
    }
}

extension Model {
    func resetAutomaticPreparation() {
        automaticQueueEpoch += 1;automaticPreparationRequest += 1;automaticRankingRequest += 1
        automaticPreparationControl.cancel();automaticPreparationControl=QueryControl()
        playbackSelectionControl.cancel();playbackSelectionControl=QueryControl()
        automaticPreparationBusy=false;automaticPreparationError=""
        preparedAutomaticSongs=[];automaticCandidates=[];automaticResolvingCandidates=[];automaticExcludedIDs=[]
        automaticRankingBusy=false;automaticRankingScheduled=false;automaticRankingError=""
        automaticDeferredSample=nil;automaticQueue.stop()
        queueLatency.record("reset",epoch:automaticQueueEpoch)
    }
    func startAutomaticQueue(currentID:String?,cached:[Recommendation]?=nil,excluding:Set<String>=[]) {
        let clickCache=cached ?? suggestions
        resetAutomaticPreparation()
        automaticExcludedIDs=excluding
        automaticQueue.start(queued:[],currentID:currentID)
        automaticQueue.pendingReplacements=1
        do {
            let start=QueueLatencyTrace.now()
            automaticCandidates=try archive.cachedAutomaticCandidates(from:clickCache,excluding:playedForYouIDs.union(excluding),currentPersistentID:currentID,knownIDs:automaticQueue.knownIDs)
            queueLatency.record("click_cache_reserved",epoch:automaticQueueEpoch,since:start,cache:automaticCandidates.count)
            replenishAutomaticQueue()
        } catch { resetAutomaticPreparation();playbackError=error.localizedDescription;onChange?() }
    }
    func startAlbumAutomaticQueue(first:PreparedAutomaticSong?,following:[PreparedAutomaticSong],albumIDs:Set<String>,candidates:[AutomaticCandidate]=[],excluding:Set<String>=[]) {
        resetAutomaticPreparation()
        guard let first else { playbackError="No verified recommended song is available after this album.";return }
        automaticExcludedIDs=excluding
        automaticQueue.start(queued:[[first.entry.persistentID]],albumIDs:albumIDs)
        automaticQueue.register([first.entry])
        preparedAutomaticSongs=Array(following.prefix(2))
        mergeAutomaticCandidates(candidates)
        prepareAutomaticSongs();scheduleAutomaticRanking()
    }
    func nextForYou() {
        guard requireCollectionConsent() else { return }
        guard playbackTrackID == nil else { return }
        playbackError=""
        if automaticQueue.enabled {
            playbackMessage=automaticQueue.pendingReplacements>0 ? "Preparing the next song…" : "One recommended song is already queued next."
            replenishAutomaticQueue();return
        }
        playbackMessage="Preparing the next song…"
        startAutomaticQueue(currentID:menuSample?.musicPersistentID)
        onChange?()
    }
    func stopAutomaticQueue() {
        resetAutomaticPreparation()
        playbackMessage="Automatic queue stopped. Songs already queued will keep playing."
        onChange?()
    }
    func observeAutomaticQueue(_ current:Sample) {
        guard automaticQueue.enabled else { return }
        if playbackTrackID != nil {
            // Registration must precede matching a newly inserted URL track. Keep the
            // newest playing observation even if an intervening sample is paused.
            if !current.running || current.state=="playing" { automaticDeferredSample=current }
            queueLatency.record("observation_deferred",epoch:automaticQueueEpoch,request:automaticActiveInsertion ?? 0)
            return
        }
        let wasEnabled=automaticQueue.enabled,debt=automaticQueue.pendingReplacements
        automaticQueue.observe(current)
        if wasEnabled && !automaticQueue.enabled { resetAutomaticPreparation();return }
        if automaticQueue.pendingReplacements>debt { queueLatency.record("transition",epoch:automaticQueueEpoch,request:automaticInsertionRequest+1) }
        replenishAutomaticQueue()
    }
    func replenishAutomaticQueue() {
        guard automaticQueue.enabled,!automaticQueue.waitingForAlbum,
              automaticQueue.pendingReplacements>0,playbackTrackID == nil else { return }
        do {
            let start=QueueLatencyTrace.now()
            while !preparedAutomaticSongs.isEmpty {
                let next=preparedAutomaticSongs.removeFirst()
                guard try archive.automaticSongIsEligible(next,excluding:playedForYouIDs,currentPersistentID:menuSample?.musicPersistentID,knownIDs:automaticQueue.knownIDs) else {
                    queueLatency.record("candidate_rejected",epoch:automaticQueueEpoch);continue
                }
                queueLatency.record("cache_hit_validated",epoch:automaticQueueEpoch,request:automaticInsertionRequest+1,since:start,cache:preparedAutomaticSongs.count)
                automaticQueue.pendingReplacements -= 1
                appendPreparedAutomaticSong(next)
                return
            }
            queueLatency.record("cache_miss",epoch:automaticQueueEpoch,request:automaticInsertionRequest+1,cache:0)
            if automaticCandidates.isEmpty && !automaticPreparationBusy && !automaticRankingBusy && !automaticRankingScheduled && !automaticRankingError.isEmpty {
                throw AppError(message:automaticPreparationError.isEmpty ? automaticRankingError : automaticPreparationError)
            }
            prepareAutomaticSongs()
        } catch {
            resetAutomaticPreparation();playbackError=error.localizedDescription;onChange?()
        }
    }
    private var automaticUsedIDs:Set<String> {
        playedForYouIDs.union(automaticExcludedIDs).union(preparedAutomaticSongs.map{$0.recommendation.id}).union(automaticInFlight.map{[$0.recommendation.id]} ?? [])
    }
    private var automaticUsedPersistentIDs:Set<String> {
        var ids=automaticQueue.knownIDs
        if let current=menuSample?.musicPersistentID { ids.insert(current) }
        ids.formUnion(preparedAutomaticSongs.map{$0.entry.persistentID})
        if let current=automaticInFlight { ids.insert(current.entry.persistentID) }
        return ids
    }
    private func mergeAutomaticCandidates(_ additions:[AutomaticCandidate],atFront:Bool=false) {
        var ids=automaticUsedIDs,persistent=automaticUsedPersistentIDs
        let existing=atFront ? additions+automaticCandidates : automaticCandidates+additions
        ids.formUnion(automaticResolvingCandidates.map{$0.recommendation.id})
        persistent.formUnion(automaticResolvingCandidates.flatMap{$0.request["ids"] as? [String] ?? []})
        automaticCandidates=existing.filter { candidate in
            let aliases=Set(candidate.request["ids"] as? [String] ?? [])
            guard !ids.contains(candidate.recommendation.id),!aliases.isEmpty,aliases.isDisjoint(with:persistent) else { return false }
            ids.insert(candidate.recommendation.id);persistent.formUnion(aliases);return true
        }
    }
    // Ranking never shares the catalog worker. A blocked next batch cannot hold up
    // the click's three cached choices, nor replace or reorder unused reservations.
    func scheduleAutomaticRanking() {
        guard automaticQueue.enabled,!automaticRankingBusy,!automaticRankingScheduled,
              automaticCandidates.count+automaticResolvingCandidates.count<6 else { return }
        automaticRankingScheduled=true
        let epoch=automaticQueueEpoch
        DispatchQueue.main.async {
            guard epoch==self.automaticQueueEpoch,self.automaticQueue.enabled else { return }
            self.automaticRankingScheduled=false
            self.rankAutomaticCandidates()
        }
    }
    private func rankAutomaticCandidates() {
        guard automaticQueue.enabled,!automaticRankingBusy else { return }
        automaticRankingBusy=true;automaticRankingError="";automaticRankingRequest += 1
        let epoch=automaticQueueEpoch,request=automaticRankingRequest,trace=queueLatency
        do {
            let start=QueueLatencyTrace.now(),snapshot=try archive.automaticCandidateSnapshot()
            trace.record("snapshot",epoch:epoch,request:request,since:start)
            let excluded=automaticUsedIDs.union(automaticCandidates.map{$0.recommendation.id}).union(automaticResolvingCandidates.map{$0.recommendation.id})
            let persistent=automaticUsedPersistentIDs.union(automaticCandidates.flatMap{$0.request["ids"] as? [String] ?? []}).union(automaticResolvingCandidates.flatMap{$0.request["ids"] as? [String] ?? []})
            let score=automaticScoreOverride
            automaticRankingQueue.async {
                let start=QueueLatencyTrace.now()
                let candidates=snapshot.candidates(excluding:excluded,persistentIDs:persistent,score:score)
                trace.record("scoring",epoch:epoch,request:request,since:start)
                DispatchQueue.main.async {
                    guard epoch==self.automaticQueueEpoch,request==self.automaticRankingRequest,self.automaticQueue.enabled else { return }
                    self.automaticRankingBusy=false
                    self.mergeAutomaticCandidates(candidates)
                    if candidates.isEmpty || (self.automaticCandidates.isEmpty && self.automaticResolvingCandidates.isEmpty && self.preparedAutomaticSongs.isEmpty && self.automaticInFlight==nil) { self.automaticRankingError="No more eligible songs are available for the automatic queue." }
                    self.replenishAutomaticQueue();self.prepareAutomaticSongs();self.onChange?()
                }
            }
        } catch {
            automaticRankingBusy=false;automaticRankingError=error.localizedDescription
            replenishAutomaticQueue();onChange?()
        }
    }
    func prepareAutomaticSongs() {
        guard automaticQueue.enabled,!automaticPreparationBusy,preparedAutomaticSongs.count<2 else { return }
        do {
            let excluded=automaticUsedIDs,persistent=automaticUsedPersistentIDs
            automaticCandidates.removeAll { excluded.contains($0.recommendation.id) || !Set($0.request["ids"] as? [String] ?? []).isDisjoint(with:persistent) }
            // Validate only a small batch. Larger ranked pools remain off the hot path.
            var candidates:[AutomaticCandidate]=[]
            while !automaticCandidates.isEmpty && candidates.count<3 {
                let candidate=automaticCandidates.removeFirst()
                if try archive.automaticRecommendationIsEligible(candidate.recommendation,excluding:excluded,currentPersistentID:menuSample?.musicPersistentID,knownIDs:persistent) { candidates.append(candidate) }
            }
            guard !candidates.isEmpty else {
                if !automaticRankingBusy && !automaticRankingScheduled && automaticRankingError.isEmpty { scheduleAutomaticRanking() }
                return
            }
            automaticResolvingCandidates=candidates
            let epoch=automaticQueueEpoch
            automaticPreparationRequest += 1
            let request=automaticPreparationRequest,control=automaticPreparationControl,override=catalogResolveOverride,trace=queueLatency
            automaticPreparationBusy=true;automaticPreparationError=""
            automaticPreparationQueue.async {
                let result=Result { () throws -> (PreparedAutomaticSong,[AutomaticCandidate]) in
                    let requests=candidates.map{$0.request},start=QueueLatencyTrace.now()
                    let resolved:[CatalogQueueSong]
                    if let override { resolved=try override(requests) }
                    else {
                        let argument=String(decoding:try JSONSerialization.data(withJSONObject:requests),as:UTF8.self)
                        resolved=try resolvedQueueSongs(Self.query("catalog",control:control,arguments:[argument,"1"]),requests:requests)
                    }
                    trace.record("catalog_resolution",epoch:epoch,request:request,since:start)
                    guard let entry=resolved.first else { throw AppError(message:"These recommendations have no verified Apple Music catalog IDs. Refresh the library or download the songs in Music before trying again.") }
                    guard candidates.indices.contains(entry.index) else { throw AppError(message:"Music returned an invalid song mapping.") }
                    return (PreparedAutomaticSong(recommendation:candidates[entry.index].recommendation,entry:entry),Array(candidates.dropFirst(entry.index+1)))
                }
                DispatchQueue.main.async {
                    guard epoch==self.automaticQueueEpoch,request==self.automaticPreparationRequest,self.automaticQueue.enabled else { return }
                    self.automaticPreparationBusy=false;self.automaticResolvingCandidates=[]
                    do {
                        let (song,remaining)=try result.get()
                        self.automaticExcludedIDs.formUnion(candidates.prefix(song.entry.index).map{$0.recommendation.id})
                        self.mergeAutomaticCandidates(remaining,atFront:true)
                        if !self.automaticQueue.knownIDs.contains(song.entry.persistentID),song.entry.persistentID != self.automaticInFlight?.entry.persistentID,
                           !self.preparedAutomaticSongs.contains(where:{$0.entry.persistentID==song.entry.persistentID}) {
                            self.preparedAutomaticSongs.append(song)
                            self.queueLatency.record("prepared",epoch:epoch,request:request,cache:self.preparedAutomaticSongs.count)
                        }
                    } catch {
                        self.automaticPreparationError=error.localizedDescription
                        self.automaticExcludedIDs.formUnion(candidates.map{$0.recommendation.id})
                    }
                    self.replenishAutomaticQueue();self.prepareAutomaticSongs()
                    if self.automaticPreparationError.isEmpty || self.automaticCandidates.isEmpty { self.scheduleAutomaticRanking() }
                    self.onChange?()
                }
            }
        } catch {
            automaticPreparationError=error.localizedDescription
            if automaticQueue.pendingReplacements>0 && preparedAutomaticSongs.isEmpty && playbackTrackID == nil {
                resetAutomaticPreparation();playbackError=error.localizedDescription;onChange?()
            }
        }
    }
    private func appendPreparedAutomaticSong(_ next:PreparedAutomaticSong) {
        let epoch=automaticQueueEpoch,control=playbackControl,override=queueAppendOverride,prefix=playbackMessage
        automaticInsertionRequest += 1
        let request=automaticInsertionRequest,trace=queueLatency
        automaticActiveInsertion=request;automaticInFlight=next;playbackTrackID=next.recommendation.id
        // Reserve/dispatch before any UI notification or recommendation refresh.
        let start=QueueLatencyTrace.now()
        trace.record("submission_dispatched",epoch:epoch,request:request)
        playbackQueue.async {
            trace.record("submission_started",epoch:epoch,request:request,since:start)
            let nativeStart=QueueLatencyTrace.now()
            let result=Result { () throws -> Void in
                if let override {
                    guard try override(["catalog_id":next.entry.catalogID])==1 else { throw AppError(message:"Music did not confirm adding the next song.") }
                } else { try MusicQueue.append(catalogID:next.entry.catalogID,control:control) }
            }
            trace.record((try? result.get()) != nil ? "ack_accepted" : "ack_failed",epoch:epoch,request:request,since:nativeStart)
            DispatchQueue.main.async {
                // An old completion may release its own slot, never a newer request's.
                guard self.automaticActiveInsertion==request else { return }
                self.automaticActiveInsertion=nil;self.automaticInFlight=nil;self.playbackTrackID=nil
                guard epoch==self.automaticQueueEpoch,self.automaticQueue.enabled else { return }
                do {
                    try result.get()
                    self.automaticQueue.append([[next.entry.persistentID]])
                    self.automaticQueue.register([next.entry])
                    try self.completeAutomaticQueue([next.recommendation],addedCount:1,prefix:prefix.hasPrefix("Started ") ? prefix : "",refresh:false)
                    let deferred=self.automaticDeferredSample;self.automaticDeferredSample=nil
                    if let deferred { self.observeAutomaticQueue(deferred) }
                    self.replenishAutomaticQueue();self.prepareAutomaticSongs()
                    // UI ranking is decoupled from the next native submission.
                    DispatchQueue.main.async { self.refreshSuggestions(background:true) }
                } catch { self.resetAutomaticPreparation();self.playbackError=error.localizedDescription }
                self.onChange?();self.refreshMenuSong()
            }
        }
        prepareAutomaticSongs();scheduleAutomaticRanking()
        onChange?()
    }
}
