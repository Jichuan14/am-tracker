import Foundation

enum AlbumListeningMode:String,CaseIterable,Identifiable {
    case automatic,album,tracks
    var id:String { rawValue }
    var label:String {
        switch self { case .automatic:return "Learn from listening";case .album:return "Prefer whole album";case .tracks:return "Prefer individual songs" }
    }
}

func albumIdentity(artist:String,title:String) -> String? {
    guard !normalized(artist).isEmpty,!normalized(title).isEmpty else { return nil }
    return "album:"+metadataKey("",artist,title)
}

struct AlbumTrack {
    let id:String,artist:String,title:String
    let disc:Int,discs:Int,number:Int,count:Int
}

struct AlbumCollection:Identifiable {
    let id:String,artist:String,title:String
    var tracks:[AlbumTrack]
    var orderedTracks:[AlbumTrack] {
        tracks.sorted { a,b in
            if a.disc != b.disc { return a.disc<b.disc }
            if a.number != b.number { return a.number<b.number }
            return a.id<b.id
        }
    }
    var playbackIssue:String? {
        guard !tracks.isEmpty else { return "No album tracks are indexed." }
        guard tracks.allSatisfy({$0.disc>0 && $0.number>0}) else {
            return "Refresh library details to confirm the order of your saved album songs."
        }
        // Album playback covers the library subset, not every song in the release.
        // Gaps and entirely unsaved discs are fine; duplicate saved positions are not.
        let positions=Set(tracks.map{"\($0.disc):\($0.number)"})
        guard positions.count==tracks.count,Set(tracks.map{$0.id}).count==tracks.count else {
            return "Some saved songs share the same disc and track number. Refresh library details to confirm their order."
        }
        return nil
    }
}

struct RecommendationFeedback {
    var liked=false,less=false,later=false
    var mode:AlbumListeningMode?
}

extension Archive {
    func feedback(_ target:String,_ kind:String,at date:Date=Date()) throws {
        try exec("INSERT INTO recommendation_feedback(target_id,kind,created_at) VALUES (?,?,?)",[target,kind,stamp(date)])
    }
    func undoRecommendationFeedback() throws {
        try exec("DELETE FROM recommendation_feedback WHERE id=(SELECT MAX(id) FROM recommendation_feedback)")
    }
    func recommendationFeedback(now:Date,targets:Set<String>?=nil) throws -> [String:RecommendationFeedback] {
        var result:[String:RecommendationFeedback]=[:]
        let ids=targets.map{Array($0).sorted()}
        if ids?.isEmpty == true { return result }
        let filter=ids.map{" WHERE target_id IN ("+Array(repeating:"?",count:$0.count).joined(separator:",")+")"} ?? ""
        for row in try rows("SELECT * FROM recommendation_feedback"+filter+" ORDER BY id",ids?.map{$0 as Any?} ?? []) {
            guard let id=row["target_id"],let kind=row["kind"],let date=parsedDate(row["created_at"]),date<=now else { continue }
            var state=result[id] ?? RecommendationFeedback()
            if kind.hasPrefix("mode_") {
                state.mode=kind=="mode_auto" ? .automatic : kind=="mode_album" ? .album : .tracks
            } else if kind=="later" {
                state.later=now.timeIntervalSince(date)<86400
            } else {
                state.liked=kind=="like";state.less=kind=="less";state.later=false
            }
            result[id]=state
        }
        return result
    }
    func albumMode(_ album:AlbumCollection,feedback:[String:RecommendationFeedback]) -> AlbumListeningMode {
        if let mode=feedback[album.id]?.mode { return mode }
        return .automatic
    }
    func albumCollections() throws -> [AlbumCollection] {
        var result:[String:AlbumCollection]=[:]
        for row in try rows("SELECT * FROM track_album_metadata ORDER BY track_id") {
            let artist=row["album_artist"] ?? "",title=row["album_title"] ?? ""
            guard let key=albumIdentity(artist:artist,title:title),let id=row["track_id"] else { continue }
            let track=AlbumTrack(id:id,artist:artist,title:title,disc:Int(row["disc_number"] ?? "0") ?? 0,
                discs:Int(row["disc_count"] ?? "0") ?? 0,number:Int(row["track_number"] ?? "0") ?? 0,count:Int(row["track_count"] ?? "0") ?? 0)
            if result[key]==nil { result[key]=AlbumCollection(id:key,artist:artist,title:title,tracks:[]) }
            result[key]?.tracks.append(track)
        }
        return result.values.sorted { $0.artist==$1.artist ? $0.title<$1.title : $0.artist<$1.artist }
    }
    func saveAlbumMetadata(_ track:[String:Any],id:String) throws {
        // Missing Album Artist remains unknown. A song's guest credits are never a substitute.
        guard track["album_artist"] != nil else { return }
        try exec("""
            INSERT INTO track_album_metadata VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(track_id) DO UPDATE SET
                album_artist=excluded.album_artist,album_title=excluded.album_title,disc_number=excluded.disc_number,
                disc_count=excluded.disc_count,track_number=excluded.track_number,track_count=excluded.track_count,updated_at=excluded.updated_at
            """,[id,track["album_artist"] as? String ?? "",track["album"] as? String ?? "",
                number(track["disc_number"]),number(track["disc_count"]),number(track["track_number"]),number(track["track_count"]),stamp()])
    }
}
