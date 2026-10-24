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
