import Foundation

enum RecommendationKind:String { case song,album }
struct Recommendation:Identifiable {
    let id:String,title:String,artist:String,album:String,catalogID:String
    let reason:String,score:Double,bucket:String
    let kind:RecommendationKind
    let albumID:String?
    let trackIDs:[String]
    let playbackIssue:String?
}
private struct TasteTrack {
    let id:String,title:String,artist:String,album:String,catalogID:String,albumID:String?
    let features:[String:Double]
    let duration:Double
    var historyWeight=0.0,recordedWeight=0.0,historyCount=0.0,libraryCount=0.0
    var lastPlayed:Date?
    var feedback=RecommendationFeedback()
    var recentCount=0,standaloneCount=0
    var standalonePeriods=Set<Int>()
    var preference:Double { max(historyWeight,recordedWeight) }
    var familiarity:Double { max(libraryCount,max(historyCount,recordedWeight)) }
}
private struct ListeningEvent {
    let id:String,track:String,start:Date,end:Date,weight:Double
}
private struct AlbumEvidence {
    var sessions=0,recentSessions=0
    var lastPlayed:Date?
}
private func unit(_ vector:[String:Double]) -> [String:Double] {
    // Fixed accumulation order keeps equivalent scores stable across Swift dictionary hash seeds.
    let length=sqrt(vector.keys.sorted().reduce(0){$0+vector[$1]!*vector[$1]!})
    return length>0 ? vector.mapValues{$0/length} : [:]
}
private func similarity(_ a:[String:Double],_ b:[String:Double]) -> Double {
    a.keys.sorted().reduce(0){$0+a[$1]!*(b[$1] ?? 0)}
}
private func add(_ vector:[String:Double],to result:inout [String:Double],weight:Double) {
    for (key,value) in vector { result[key,default:0] += value*weight }
}
private func daysSince(_ date:Date?,now:Date) -> Double? {
    date.map{max(0,now.timeIntervalSince($0)/86400)}
}
private func rediscovery(_ date:Date?,familiar:Bool,now:Date) -> Double {
    guard familiar,let days=daysSince(date,now:now),days>=3 else { return 0 }
    return min(1,(days-3)/11)
}
private func freshnessFactor(_ date:Date?,recentCount:Int,now:Date) -> Double {
    let days=daysSince(date,now:now) ?? .infinity
    let recency=days<3 ? 0.35 : days<7 ? 0.75 : 1.0
    return recency/(1+0.35*Double(max(0,recentCount-1)))
}

extension Archive {
    func recommendationForTrack(_ id:String) throws -> Recommendation? {
        guard let row=try rows("SELECT t.*,m.album_artist,m.album_title FROM music_tracks t LEFT JOIN track_album_metadata m ON m.track_id=t.id WHERE t.id=?",[id]).first else { return nil }
        let artist=row["album_artist"] ?? "",album=row["album_title"] ?? row["album"] ?? ""
        return Recommendation(id:id,title:row["title"] ?? "",artist:artist.isEmpty ? "Unknown album artist" : artist,
            album:album,catalogID:"",reason:"",score:0,bucket:"Familiar",kind:.song,
            albumID:albumIdentity(artist:artist,title:album),trackIDs:[id],playbackIssue:nil)
    }
    func recommendations(now:Date=Date(),limit:Int=10,log:Bool=false) throws -> [Recommendation] {
        try syncUnifiedHistory()
        let feedback=try recommendationFeedback(now:now),albums=try albumCollections()
        let playbackCooldowns=try forYouPlaybackCooldowns(now:now)
        let albumMap=Dictionary(uniqueKeysWithValues:albums.map{($0.id,$0)})
        let modes=Dictionary(uniqueKeysWithValues:albums.map{($0.id,albumMode($0,feedback:feedback))})
        var tracks:[String:TasteTrack]=[:]
        for r in try rows("SELECT t.*,m.album_artist,m.album_title FROM music_tracks t LEFT JOIN track_album_metadata m ON m.track_id=t.id ORDER BY t.id") {
            let id=r["id"]!,artist=r["album_artist"] ?? "",album=r["album_title"] ?? r["album"] ?? "",genre=r["genre"] ?? ""
            let key=albumIdentity(artist:artist,title:album)
            var vector:[String:Double]=[:]
            if !artist.isEmpty { vector["artist:"+normalized(artist)]=3 }
            if !genre.isEmpty { vector["genre:"+normalized(genre)]=1 }
            if let key { vector[key]=0.5 }
            var track=TasteTrack(id:id,title:r["title"] ?? "",artist:artist,album:album,catalogID:"",albumID:key,features:unit(vector),duration:Double(r["duration"] ?? "0") ?? 0)
            track.feedback=feedback[id] ?? RecommendationFeedback();tracks[id]=track
        }
        let history=try rows("SELECT * FROM listening_history WHERE status='active' AND music_order IS NOT NULL ORDER BY music_order")
        // Preserve canonical occurrences, but do not treat each song in an album run as an independent choice.
        var start=0
        while start<history.count {
            var end=start+1
            let album=tracks[history[start]["track_id"] ?? ""]?.albumID
            while album != nil && end<history.count && tracks[history[end]["track_id"] ?? ""]?.albumID==album &&
                history[end]["music_snapshot_id"]==history[start]["music_snapshot_id"] { end += 1 }
            let weight=0.35/sqrt(Double(end-start))
            for row in history[start..<end] {
                if let id=row["track_id"] { tracks[id]?.historyWeight += weight;tracks[id]?.historyCount += 1 }
            }
            start=end
        }
        for r in try rows("SELECT l.*,a.track_id FROM library_tracks l JOIN track_aliases a ON a.kind='persistent' AND a.value=upper(l.persistent_id)") {
            guard let id=r["track_id"] else { continue }
            let count=max(tracks[id]?.libraryCount ?? 0,Double(r["play_count"] ?? "0") ?? 0)
            tracks[id]?.libraryCount=count
            if let date=parsedDate(r["last_played"]),date<=now {
                let last=max(tracks[id]?.lastPlayed ?? .distantPast,date)
                tracks[id]?.lastPlayed=last
            }
        }
        // unified_history may expose multiple catalog aliases: use each canonical event only once.
        var seen=Set<String>(),events:[ListeningEvent]=[]
        for r in try rows("SELECT * FROM unified_history WHERE recording_segments>0 ORDER BY datetime(first_observed_at),id") {
            guard let eventID=r["id"],seen.insert(eventID).inserted,let id=r["track_id"],
                  let begin=parsedDate(r["first_observed_at"]),begin<=now else { continue }
            let heard=max(0,Double(r["observed_listening_seconds"] ?? "0") ?? 0),duration=Double(r["duration"] ?? "0") ?? 0
            let weight=heard>=10 ? min(1,heard/(duration>0 ? duration : 240)) : 0
            let end=parsedDate(r["last_listening_at"] ?? r["first_observed_at"]) ?? begin
            guard end<=now else { continue }
            if heard>=min(30,duration>0 ? duration*0.3 : 30) {
                events.append(ListeningEvent(id:eventID,track:id,start:begin,end:end,weight:weight))
                let last=max(tracks[id]?.lastPlayed ?? .distantPast,end)
                tracks[id]?.lastPlayed=last
                if now.timeIntervalSince(end)<3*86400 { tracks[id]?.recentCount += 1 }
            } else { tracks[id]?.recordedWeight += weight }
        }
        var evidence:[String:AlbumEvidence]=[:]
        var eventStart=0,period=0
        while eventStart<events.count {
            var end=eventStart+1
            let key=tracks[events[eventStart].track]?.albumID
            while key != nil && end<events.count && tracks[events[end].track]?.albumID==key &&
                events[end].start.timeIntervalSince(events[end-1].end)>=0 && events[end].start.timeIntervalSince(events[end-1].end)<=1200 { end += 1 }
            let run=Array(events[eventStart..<end]),unique=Set(run.map{$0.track}),albumContext=unique.count>=3
            if eventStart==0 || events[eventStart].start.timeIntervalSince(events[eventStart-1].end)>1200 { period += 1 }
            for event in run {
                tracks[event.track]?.recordedWeight += event.weight/(albumContext ? sqrt(Double(unique.count)) : 1)
                if !albumContext {
                    tracks[event.track]?.standaloneCount += 1;tracks[event.track]?.standalonePeriods.insert(period)
                }
            }
            if let key,let collection=albumMap[key],collection.playbackIssue==nil {
                let substantiallyHeard=Set(run.filter{$0.weight>=0.5}.map{$0.track})
                if substantiallyHeard.count>=max(3,Int(ceil(Double(collection.tracks.count)*0.6))) {
                    var value=evidence[key] ?? AlbumEvidence();value.sessions += 1
                    let date=run.map{$0.end}.max()!
                    value.lastPlayed=max(value.lastPlayed ?? .distantPast,date)
                    if now.timeIntervalSince(date)<3*86400 { value.recentSessions += 1 }
                    evidence[key]=value
                }
            }
            eventStart=end
        }
        // Last-played metadata can establish recent album coverage, never invented per-song events.
        for album in albums where album.playbackIssue==nil {
            let dates=album.tracks.compactMap{tracks[$0.id]?.lastPlayed}.sorted()
            var left=0
            let duration=album.tracks.reduce(0.0) { total,t in
                let seconds=tracks[t.id]?.duration ?? 0
                return total+(seconds>0 ? seconds : 240)
            }
            for right in dates.indices {
                // An album-sized window avoids interpreting scattered single-song listens as an album session.
                while dates[right].timeIntervalSince(dates[left])>max(1800,duration*1.5) { left += 1 }
                if right-left+1>=max(3,Int(ceil(Double(album.tracks.count)*0.6))) {
                    var value=evidence[album.id] ?? AlbumEvidence()
                    value.lastPlayed=max(value.lastPlayed ?? .distantPast,dates[right]);evidence[album.id]=value
                }
            }
        }
        let prefersAlbum=Set(albums.filter {
            let mode=modes[$0.id] ?? .automatic
            return mode == .album || (mode == .automatic && (evidence[$0.id]?.sessions ?? 0)>=2)
        }.map{$0.id})
        // A recently heard album cannot re-enter the batch via its component songs.
        let coolingAlbums=Set(prefersAlbum.filter { daysSince(evidence[$0]?.lastPlayed,now:now).map{$0<1} ?? false })
        var main:[String:Double]=[:],current:[String:Double]=[:]
        for track in tracks.values.sorted(by:{$0.id<$1.id}) where !track.feedback.less {
            if let key=track.albumID,(feedback[key]?.less ?? false) { continue }
            let albumSize=track.albumID.flatMap{albumMap[$0]?.tracks.count} ?? 1
            let albumFactor=track.albumID.map{prefersAlbum.contains($0)} == true ? 1/Double(max(1,albumSize)) : 1
            add(track.features,to:&main,weight:(log1p(track.familiarity)+(track.feedback.liked ? 2 : 0))*albumFactor)
        }
        for album in albums where feedback[album.id]?.liked == true {
            if let track=album.tracks.first.flatMap({tracks[$0.id]}) { add(track.features,to:&main,weight:2) }
        }
        let long=unit(main),recent=Array(events.filter{now.timeIntervalSince($0.end)<=1800}.suffix(5))
        for (i,event) in recent.enumerated() {
            if let track=tracks[event.track] { add(track.features,to:&current,weight:pow(0.7,Double(recent.count-1-i))) }
        }
        current=unit(current)
        var transitions:[String:[String:Double]]=[:]
        if events.count>1 {
            for i in 1..<events.count {
                let a=events[i-1],b=events[i],gap=b.start.timeIntervalSince(a.end)
                if a.track != b.track && gap>=0 && gap<=1200 {
                    let sameAlbum=tracks[a.track]?.albumID != nil && tracks[a.track]?.albumID==tracks[b.track]?.albumID
                    transitions[a.track,default:[:]][b.track,default:0] += sameAlbum ? 0.15 : 1
                }
            }
        }
        let negatives=tracks.values.filter{$0.feedback.less}.map{$0.features} + albums.filter{feedback[$0.id]?.less == true}.compactMap { a in a.tracks.first.flatMap{tracks[$0.id]?.features} }
        let maxFamiliarity=max(1,tracks.values.map{log1p($0.familiarity)}.max() ?? 1)
        let anchor=recent.last?.track
        var scored:[Recommendation]=[],vectors:[String:[String:Double]]=[:]
        func baseScore(features:[String:Double],familiarity:Double,liked:Bool,last:Date?,recentCount:Int,neighbor:Double) -> Double {
            let established=0.5*similarity(features,long)+0.5*log1p(familiarity)/maxFamiliarity
            let neglected=rediscovery(last,familiar:familiarity>=10 || liked,now:now)
            let transition=neighbor>=0.2 ? neighbor/(neighbor+2) : 0
            let negative=negatives.map{similarity(features,$0)}.max() ?? 0
            let value=(current.isEmpty ? 0.6 : 0.5)*established + 0.1*similarity(features,current) + 0.1*transition + 0.3*neglected + (liked ? 0.15 : 0) - 0.15*negative
            return value*freshnessFactor(last,recentCount:recentCount,now:now)
        }
        func bucket(familiarity:Double,liked:Bool,last:Date?) -> String {
            if (familiarity>=10 || liked) && (daysSince(last,now:now).map{$0>=3} ?? false) { return "Rediscover" }
            return familiarity>=3 || liked ? "Familiar" : "Explore your library"
        }
        for t in tracks.values {
            guard playbackCooldowns[t.id]==nil else { continue }
            guard !t.feedback.less,!t.feedback.later,!(daysSince(t.lastPlayed,now:now).map{$0<1} ?? false) else { continue }
            if let key=t.albumID {
                let state=feedback[key] ?? RecommendationFeedback()
                if state.less || state.later || coolingAlbums.contains(key) { continue }
                let independentlyChosen=t.feedback.liked || (t.standaloneCount>=3 && t.standalonePeriods.count>=2)
                if prefersAlbum.contains(key) && !independentlyChosen { continue }
            }
            let neighbor=anchor.flatMap{transitions[$0]?[t.id]} ?? 0
            let score=baseScore(features:t.features,familiarity:t.familiarity,liked:t.feedback.liked,last:t.lastPlayed,recentCount:t.recentCount,neighbor:neighbor)
            guard score>0 else { continue }
            let category=bucket(familiarity:t.familiarity,liked:t.feedback.liked,last:t.lastPlayed)
            let reason=category=="Rediscover" ? "A longtime favorite, last played \(Int(daysSince(t.lastPlayed,now:now)!)) days ago" :
                t.feedback.liked ? "You marked this as a favorite" : t.familiarity>=3 ? "A familiar song from your listening history" : "A less-played song from your collection"
            scored.append(Recommendation(id:t.id,title:t.title,artist:t.artist.isEmpty ? "Unknown album artist" : t.artist,
                album:t.album,catalogID:t.catalogID,reason:reason,score:score,bucket:category,kind:.song,albumID:t.albumID,trackIDs:[t.id],playbackIssue:nil))
            vectors[t.id]=t.features
        }
        for album in albums where prefersAlbum.contains(album.id) {
            guard playbackCooldowns[album.id]==nil, !album.tracks.contains(where:{playbackCooldowns[$0.id] != nil}) else { continue }
            let state=feedback[album.id] ?? RecommendationFeedback(),ev=evidence[album.id] ?? AlbumEvidence()
            guard !state.less,!state.later,!coolingAlbums.contains(album.id) else { continue }
            let members=album.tracks.compactMap{tracks[$0.id]}
            guard !members.isEmpty else { continue }
            let counts=members.map{$0.familiarity}.sorted(),familiarity=counts[counts.count/2]
            // Listening-style defaults do not create preference for an otherwise unheard album.
            guard familiarity>0 || state.liked || ev.sessions>0 else { continue }
            var features:[String:Double]=[:]
            for member in members { add(member.features,to:&features,weight:1/Double(members.count)) }
            features=unit(features)
            let neighbor=members.map{t in anchor.flatMap{transitions[$0]?[t.id]} ?? 0}.max() ?? 0
            let score=baseScore(features:features,familiarity:familiarity,liked:state.liked,last:ev.lastPlayed,recentCount:ev.recentSessions,neighbor:neighbor)
            guard score>0 else { continue }
            let category=bucket(familiarity:familiarity,liked:state.liked,last:ev.lastPlayed)
            let reason=category=="Rediscover" ? "An album you enjoy as a whole, last heard \(Int(daysSince(ev.lastPlayed,now:now)!)) days ago" :
                state.liked ? "You marked this album as a favorite · play your saved songs in order" : "You prefer album listening · play your saved songs in order"
            // Less/Not now on a component song must never be bypassed by album playback.
            let blocked=members.contains{$0.feedback.less || $0.feedback.later}
            let issue=blocked ? "A song on this album is hidden by your feedback. Undo that feedback before playing the whole album." : album.playbackIssue
            scored.append(Recommendation(id:album.id,title:album.title,artist:album.artist,album:album.title,catalogID:"",reason:reason,
                score:score,bucket:category,kind:.album,albumID:album.id,trackIDs:album.orderedTracks.map{$0.id},playbackIssue:issue))
            vectors[album.id]=features
        }
        scored.sort{$0.score==$1.score ? $0.id<$1.id : $0.score>$1.score}
        var selected:[Recommendation]=[],artistCounts:[String:Int]=[:]
        for index in 0..<max(0,limit) {
            let desired=index<Int(Double(limit)*0.6) ? "Rediscover" : index<Int(Double(limit)*0.8) ? "Familiar" : "Explore your library"
            let remaining=scored.filter { candidate in
                !selected.contains { picked in picked.id==candidate.id || (candidate.albumID != nil && candidate.albumID==picked.albumID && (candidate.kind == .album || picked.kind == .album)) }
            }
            func choose(_ candidates:[Recommendation]) -> Recommendation? {
                candidates.max { a,b in
                    func adjusted(_ c:Recommendation) -> Double {
                        let redundancy=selected.map{similarity(vectors[c.id] ?? [:],vectors[$0.id] ?? [:])}.max() ?? 0
                        return c.score-0.12*redundancy
                    }
                    let av=adjusted(a),bv=adjusted(b);return av==bv ? a.id>b.id : av<bv
                }
            }
            let diverse=remaining.filter{(artistCounts[normalized($0.artist)] ?? 0)<2 && normalized($0.artist) != selected.last.map{normalized($0.artist)}}
            guard let pick=choose(diverse.filter{$0.bucket==desired}) ?? choose(remaining.filter{$0.bucket==desired && (artistCounts[normalized($0.artist)] ?? 0)<2}) ?? choose(diverse) ?? choose(remaining) else { break }
            selected.append(pick);artistCounts[normalized(pick.artist),default:0] += 1
        }
        if log && !selected.isEmpty {
            let json=String(data:try JSONSerialization.data(withJSONObject:selected.map{$0.id}),encoding:.utf8)!
            try exec("INSERT INTO recommendation_batches(created_at,track_ids) VALUES (?,?)",[stamp(now),json])
        }
        return selected
    }
}
