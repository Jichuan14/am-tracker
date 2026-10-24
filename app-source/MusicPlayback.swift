import Foundation
import AppKit

extension Archive {
    // Playback starts are selection cooldowns, not evidence of a completed listen.
    func forYouPlaybackCooldowns(now:Date=Date()) throws -> [String:Double] {
        let saved=try value("for_you_playback_cooldowns")
        guard !saved.isEmpty else { return [:] }
        let entries=try JSONDecoder().decode([String:Double].self,from:Data(saved.utf8))
        return entries.filter { now.timeIntervalSince1970-$0.value<86400 && $0.value<=now.timeIntervalSince1970 }
    }
    func rememberForYouPlayback(_ song:Recommendation,at now:Date=Date()) throws {
        try rememberForYouSelections(Set([song.id]+song.trackIDs),at:now)
    }
    func rememberForYouSelections(_ ids:Set<String>,at now:Date=Date()) throws {
        var entries=try forYouPlaybackCooldowns(now:now)
        for id in ids { entries[id]=now.timeIntervalSince1970 }
        try meta("for_you_playback_cooldowns",String(decoding:try JSONEncoder().encode(entries),as:UTF8.self))
    }

    func feedbackForCurrentSong(_ sample:Sample,_ kind:String) throws {
        guard let persistentID=sample.musicPersistentID else {
            throw AppError(message:"Music has no library song selected to rate.")
        }
        var song=ImportedSong(title:sample.title)
        song.artist=sample.artist;song.album=sample.album;song.persistentID=persistentID
        let id=try resolve(song)
        if let artist=sample.albumMetadata["album_artist"] as? String,!artist.isEmpty,
           number(sample.albumMetadata["track_number"])>0,number(sample.albumMetadata["track_count"])>0 {
            try saveAlbumMetadata(sample.albumMetadata,id:id)
        }
        try feedback(id,kind)
    }

    func automaticQueueSongs(excluding:Set<String>,currentPersistentID:String?,limit:Int=5,excludingPersistentIDs:Set<String>=[]) throws -> [Recommendation] {
        let candidates=try recommendations(limit:100).filter { song in
            guard song.kind == .song,song.playbackIssue==nil,!excluding.contains(song.id) else { return false }
            let ids=try playbackIDs(for:song.id)
            return !ids.isEmpty && !ids.contains(currentPersistentID ?? "") && Set(ids).isDisjoint(with:excludingPersistentIDs)
        }
        return Array(candidates.prefix(max(0,limit)))
    }

    // A prepared selection keeps its rank. Only fresh safety/eligibility facts are checked here.
    func automaticSongIsEligible(_ next:PreparedAutomaticSong,excluding:Set<String>,currentPersistentID:String?,knownIDs:Set<String>,now:Date=Date()) throws -> Bool {
        guard MusicQueue.validCatalogID(next.entry.catalogID) else { return false }
        return try automaticRecommendationIsEligible(next.recommendation,resolvedID:next.entry.persistentID,excluding:excluding,currentPersistentID:currentPersistentID,knownIDs:knownIDs,now:now)
    }
    func automaticRecommendationIsEligible(_ song:Recommendation,resolvedID:String?=nil,excluding:Set<String>,currentPersistentID:String?,knownIDs:Set<String>,now:Date=Date()) throws -> Bool {
        guard song.kind == .song,song.playbackIssue==nil,!excluding.contains(song.id) else { return false }
        let ids=try playbackIDs(for:song.id)
        guard !ids.isEmpty,(resolvedID.map({ids.contains($0)}) ?? true),!ids.contains(currentPersistentID ?? ""),Set(ids).isDisjoint(with:knownIDs) else { return false }
        guard let row=try rows("SELECT m.album_artist,m.album_title FROM music_tracks t LEFT JOIN track_album_metadata m ON m.track_id=t.id WHERE t.id=?",[song.id]).first else { return false }
        let albumID=albumIdentity(artist:row["album_artist"] ?? "",title:row["album_title"] ?? "") ?? song.albumID
        let targets=Set([song.id]+(albumID.map{[$0]} ?? []))
        let feedback=try recommendationFeedback(now:now,targets:targets)
        let cooldowns=try forYouPlaybackCooldowns(now:now)
        guard !targets.contains(where:{feedback[$0]?.less == true || feedback[$0]?.later == true || cooldowns[$0] != nil}) else { return false }
        if let albumID,feedback[song.id]?.liked != true {
            let album=AlbumCollection(id:albumID,artist:row["album_artist"] ?? "",title:row["album_title"] ?? "",tracks:[])
            if albumMode(album,feedback:feedback) == .album,
               try !hasIndependentQueueListeningEvidence(for:song.id,now:now) { return false }
        }
        let library=try rows("SELECT l.last_played FROM library_tracks l JOIN track_aliases a ON a.kind='persistent' AND a.value=upper(l.persistent_id) WHERE a.track_id=?",[song.id])
        if library.contains(where:{parsedDate($0["last_played"]).map{now.timeIntervalSince($0)>=0 && now.timeIntervalSince($0)<86400} ?? false}) { return false }
        let recorded=try rows("SELECT first_observed_at,last_listening_at,observed_listening_seconds,duration FROM unified_history WHERE track_id=? AND recording_segments>0",[song.id])
        if recorded.contains(where:{ r in
            let heard=Double(r["observed_listening_seconds"] ?? "0") ?? 0,duration=Double(r["duration"] ?? "0") ?? 0
            guard heard>=min(30,duration>0 ? duration*0.3 : 30),let date=parsedDate(r["last_listening_at"] ?? r["first_observed_at"]) else { return false }
            return now.timeIntervalSince(date)>=0 && now.timeIntervalSince(date)<86400
        }) { return false }
        return true
    }
    // This is the same standalone-count/period exception used by scoring. Only
    // whole-album components without an explicit Like need this targeted check.
    // Album runs are identified from neighboring valid events, not raw play counts.
    func hasIndependentQueueListeningEvidence(for trackID:String,now:Date) throws -> Bool {
        struct Event { let track:String,album:String?;let start:Date,end:Date }
        var events:[Event]=[],seen=Set<String>()
        for r in try rows("SELECT h.id,h.track_id,h.first_observed_at,h.last_listening_at,h.observed_listening_seconds,h.duration,m.album_artist,m.album_title,t.album FROM unified_history h LEFT JOIN track_album_metadata m ON m.track_id=h.track_id LEFT JOIN music_tracks t ON t.id=h.track_id WHERE h.recording_segments>0 ORDER BY datetime(h.first_observed_at),h.id") {
            guard let id=r["id"],seen.insert(id).inserted,let track=r["track_id"],let start=parsedDate(r["first_observed_at"]),start<=now else { continue }
            let heard=max(0,Double(r["observed_listening_seconds"] ?? "0") ?? 0),duration=Double(r["duration"] ?? "0") ?? 0
            let end=parsedDate(r["last_listening_at"] ?? r["first_observed_at"]) ?? start
            guard end<=now,heard>=min(30,duration>0 ? duration*0.3 : 30) else { continue }
            events.append(Event(track:track,album:albumIdentity(artist:r["album_artist"] ?? "",title:r["album_title"] ?? r["album"] ?? ""),start:start,end:end))
        }
        var start=0,period=0,count=0,periods=Set<Int>()
        while start<events.count {
            var end=start+1
            let album=events[start].album
            while album != nil && end<events.count && events[end].album==album &&
                  events[end].start.timeIntervalSince(events[end-1].end)>=0 && events[end].start.timeIntervalSince(events[end-1].end)<=1200 { end += 1 }
            if start==0 || events[start].start.timeIntervalSince(events[start-1].end)>1200 { period += 1 }
            let run=events[start..<end]
            if Set(run.map{$0.track}).count<3 {
                for event in run where event.track==trackID { count += 1;periods.insert(period) }
            }
            if count>=3 && periods.count>=2 { return true }
            start=end
        }
        return false
    }

    func cachedAutomaticCandidates(from list:[Recommendation],excluding:Set<String>,currentPersistentID:String?,knownIDs:Set<String>,limit:Int=3) throws -> [AutomaticCandidate] {
        var result:[AutomaticCandidate]=[],reserved=knownIDs,excluded=excluding
        for song in list {
            guard result.count<max(0,limit) else { break }
            guard try automaticRecommendationIsEligible(song,excluding:excluded,currentPersistentID:currentPersistentID,knownIDs:reserved) else { continue }
            let request=try queueRequest(for:song.id)
            result.append(AutomaticCandidate(recommendation:song,request:request))
            reserved.formUnion(request["ids"] as? [String] ?? []);excluded.insert(song.id)
        }
        return result
    }

    func automaticCandidateSnapshot() throws -> AutomaticCandidateSnapshot {
        let ranking=try recommendationSnapshot()
        var ids:[String:[String]]=[:],catalogs:[String:[String]]=[:]
        for r in try rows("SELECT a.track_id,a.kind,a.value FROM track_aliases a LEFT JOIN library_tracks l ON a.kind='persistent' AND upper(l.persistent_id)=a.value WHERE a.kind IN ('persistent','catalog') ORDER BY (l.persistent_id IS NOT NULL) DESC,a.value") {
            guard let track=r["track_id"],let value=r["value"] else { continue }
            if r["kind"]=="persistent",value.range(of:"^[0-9A-F]{16}$",options:.regularExpression) != nil { ids[track,default:[]].append(value) }
            if r["kind"]=="catalog",MusicQueue.validCatalogID(value) { catalogs[track,default:[]].append(value) }
        }
        var requests:[String:[String:Any]]=[:]
        for (track,aliases) in ids {
            var request:[String:Any]=["ids":aliases]
            if let values=catalogs[track],values.count==1 { request["catalog_id"]=values[0] }
            requests[track]=request
        }
        return AutomaticCandidateSnapshot(ranking:ranking,requests:requests)
    }

    func nextForYou(from list:[Recommendation]?=nil,excluding:Set<String>,currentPersistentID:String?) throws -> Recommendation? {
        let candidates=try (list ?? recommendations()).filter { song in
            guard song.playbackIssue==nil,!excluding.contains(song.id) else { return false }
            let ids=try song.trackIDs.flatMap{try playbackIDs(for:$0)}
            return !ids.isEmpty && !ids.contains(currentPersistentID ?? "")
        }
        return candidates.randomElement()
    }

    func playbackIDs(for trackID:String) throws -> [String] {
        // Prefer the latest library index, but let Music verify historical aliases too.
        try rows("SELECT a.value FROM track_aliases a LEFT JOIN library_tracks l ON upper(l.persistent_id)=a.value WHERE a.track_id=? AND a.kind='persistent' ORDER BY (l.persistent_id IS NOT NULL) DESC,a.value",[trackID])
            .compactMap { row in
                guard let id=row["value"]?.uppercased(),id.count==16,id.range(of:"^[0-9A-F]{16}$",options:.regularExpression) != nil else { return nil }
                return id
            }
    }
    func queueRequest(for trackID:String) throws -> [String:Any] {
        let ids=try playbackIDs(for:trackID)
        let catalogs=try rows("SELECT value FROM track_aliases WHERE kind='catalog' AND track_id=? ORDER BY value",[trackID]).compactMap{$0["value"]}.filter{MusicQueue.validCatalogID($0)}
        var request:[String:Any]=["ids":ids]
        if catalogs.count==1 { request["catalog_id"]=catalogs[0] }
        return request
    }
    func playbackRequest(for recommendation:Recommendation) throws -> [String:Any] {
        if let issue=recommendation.playbackIssue { throw AppError(message:issue) }
        if recommendation.kind == .song {
            let ids=try playbackIDs(for:recommendation.id)
            guard !ids.isEmpty else { throw AppError(message:"This song has no matching Music library ID. Use Find in Music to locate it.") }
            return ["kind":"song","ids":ids]
        }
        guard let album=try albumCollections().first(where:{$0.id==recommendation.id}) else { throw AppError(message:"Refresh the library before playing this album.") }
        if let issue=album.playbackIssue { throw AppError(message:issue) }
        let states=try recommendationFeedback(now:Date())
        guard states[album.id]?.less != true,states[album.id]?.later != true,
              !album.tracks.contains(where:{states[$0.id]?.less == true || states[$0.id]?.later == true}) else {
            throw AppError(message:"This album or one of its songs is hidden by your feedback.")
        }
        let items=try album.orderedTracks.map { track -> [String:Any] in
            let ids=try playbackIDs(for:track.id)
            guard !ids.isEmpty else { throw AppError(message:"An album track is missing from your Music library. Refresh library details before trying again.") }
            return ["ids":ids,"disc":track.disc,"discs":track.discs,"number":track.number,"count":track.count]
        }
        var token=try value("album_playlist_owner")
        if token.isEmpty { token=UUID().uuidString;try meta("album_playlist_owner",token) }
        return ["kind":"album","album_artist":album.artist,"album":album.title,"tracks":items,
            "owner":token,"previous_playlist_id":try value("album_playlist_id")]
    }
}

extension Sample {
    var albumArtistLabel:String {
        let artist=albumMetadata["album_artist"] as? String ?? ""
        return artist.isEmpty ? "Unknown album artist" : artist
    }
    var musicPersistentID:String? {
        let id=key.uppercased()
        return running && !title.isEmpty && id.count==16 && id.range(of:"^[0-9A-F]{16}$",options:.regularExpression) != nil ? id : nil
    }
}

func confirmPlayback(_ response:[String:Any],requestedIDs:[String],albumCount:Int?=nil) throws {
    switch response["status"] as? String {
    case "playing":
        guard let id=response["persistent_id"] as? String,requestedIDs.contains(id) else {
            throw AppError(message:"Music did not confirm the selected song. Try again.")
        }
        if let albumCount {
            guard (response["track_count"] as? NSNumber)?.intValue==albumCount,response["from_start"] as? Bool==true else {
                throw AppError(message:"Music did not confirm your saved album songs from the beginning.")
            }
        }
    case "not_found", "invalid_id":
        throw AppError(message:"This song is no longer in your Music library. Use Find in Music to locate it.")
    case "unavailable":
        throw AppError(message:"Music could not start this song. Check that it is available in Music, then try again.")
    case "incomplete_album", "invalid_album":
        throw AppError(message:"Music could not find or confirm the order of your saved album songs. Refresh library details, or locate the album in Music.")
    default:
        throw AppError(message:"Music did not confirm playback. Try again.")
    }
}
