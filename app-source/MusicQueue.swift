import AppKit

// Used only inside the automatic queue ledger; never merges library/history records.
struct QueueSongMetadata {
    let title:String
    let artist:String
    let album:String
    let duration:Double
    func matches(_ sample:Sample) -> Bool {
        !title.isEmpty && !artist.isEmpty && !album.isEmpty && duration.isFinite && duration>0 &&
        sample.title==title && sample.artist==artist && sample.album==album &&
        sample.duration.isFinite && sample.duration>0 && abs(sample.duration-duration)<=2
    }
}
struct CatalogQueueSong {
    let index:Int
    let persistentID:String
    let catalogID:String
    var metadata:QueueSongMetadata?=nil
}
func resolvedQueueSongs(_ response:[String:Any],requests:[[String:Any]]) throws -> [CatalogQueueSong] {
    guard response["status"] as? String == "resolved",let tracks=response["tracks"] as? [[String:Any]],tracks.count==requests.count else {
        throw AppError(message:"Music could not resolve the exact songs for background queueing.")
    }
    var result:[CatalogQueueSong]=[]
    for (index,track) in tracks.enumerated() {
        guard track["index"] as? Int==index else { throw AppError(message:"Music returned an invalid song mapping.") }
        guard track["status"] as? String == "resolved" else { continue }
        guard let pid=track["persistent_id"] as? String,(requests[index]["ids"] as? [String])?.contains(pid)==true,
              let catalog=track["catalog_id"] as? String,MusicQueue.validCatalogID(catalog) else {
            throw AppError(message:"Music returned conflicting song identifiers. Nothing was queued.")
        }
        var entry=CatalogQueueSong(index:index,persistentID:pid,catalogID:catalog)
        if let title=track["title"] as? String,let artist=track["artist"] as? String,let album=track["album"] as? String,
           let duration=track["duration"] as? NSNumber {
            entry.metadata=QueueSongMetadata(title:title,artist:artist,album:album,duration:duration.doubleValue)
        }
        result.append(entry)
    }
    return result
}
enum MusicQueue {
    static func validCatalogID(_ id:String) -> Bool { !id.isEmpty && id.count<=19 && id.first != "0" && id.utf8.allSatisfy({$0>=48 && $0<=57}) }
    static func confirm(_ response:[String:Any],catalogID:String) throws {
        guard response["status"] as? String == "accepted",response["catalog_id"] as? String==catalogID,
              let statuses=response["return_statuses"] as? [NSNumber],!statuses.isEmpty,statuses.allSatisfy({$0.intValue==0}) else {
            let detail=response["error"] as? String ?? ""
            throw AppError(message:"Music did not confirm background queue insertion."+(detail.isEmpty ? "" : " "+detail)+" Automatic retries are stopped to avoid duplicates.")
        }
    }
    static func append(catalogID:String,control:QueryControl) throws {
        guard validCatalogID(catalogID) else { throw AppError(message:"Invalid catalog song ID.") }
        try confirm(runHelper(argument:catalogID,control:control),catalogID:catalogID)
    }
    static func checkAvailability(control:QueryControl) throws {
        guard try runHelper(argument:"--check",control:control)["status"] as? String == "available" else {
            throw AppError(message:"Background queueing is unavailable on this version of Music. Current playback was kept unchanged.")
        }
    }
    private static func runHelper(argument:String,control:QueryControl) throws -> [String:Any] {
        let url=Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AMQueue")
        guard FileManager.default.isExecutableFile(atPath:url.path) else { throw AppError(message:"Background queue helper is missing. Rebuild AM Track.") }
        let process=Process(),out=Pipe(),errors=Pipe()
        process.executableURL=url;process.arguments=[argument];process.standardOutput=out;process.standardError=errors
        try control.launch(process)
        let deadline=DispatchWorkItem { control.terminate(process) }
        DispatchQueue.global().asyncAfter(deadline:.now()+25,execute:deadline)
        let data=out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit();deadline.cancel()
        guard let response=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
            throw AppError(message:"Background queue insertion was not confirmed. Automatic retries are stopped to avoid duplicates.")
        }
        return response
    }
}

// Tracks only songs AM Track added. No reading of Music's upcoming queue is needed.
// A changed playing track accounts for finishes and skips in the same way.
struct AutomaticQueue {
    private(set) var enabled=false
    private(set) var waitingForAlbum=false
    private(set) var songs:[Set<String>]=[]
    private(set) var albumIDs=Set<String>()
    private(set) var knownIDs=Set<String>()
    var pendingReplacements=0
    private var metadata:[String:QueueSongMetadata]=[:]
    private var observedIDs=Set<String>()
    mutating func register(_ entries:[CatalogQueueSong]) {
        for entry in entries where knownIDs.contains(entry.persistentID) {
            if let details=entry.metadata { metadata[entry.persistentID]=details }
        }
    }

    mutating func start(queued:[[String]],currentID:String?=nil,albumIDs:Set<String>=[]) {
        self=AutomaticQueue()
        enabled=true;self.albumIDs=albumIDs;knownIDs=albumIDs;waitingForAlbum = !albumIDs.isEmpty
        if albumIDs.isEmpty,let currentID { songs.append([currentID]);knownIDs.insert(currentID);observedIDs=[currentID] }
        append(queued)
    }
    mutating func append(_ queued:[[String]]) {
        for ids in queued {
            let values=Set(ids)
            knownIDs.formUnion(values)
            if !values.isEmpty && !songs.contains(where:{!$0.isDisjoint(with:values)}) { songs.append(values) }
        }
    }
    mutating func stop() { self=AutomaticQueue() }
    mutating func observe(_ sample:Sample) {
        guard enabled else { return }
        if !sample.running { stop();return }
        // A pause or a brief stopped state between songs is not a consumed song.
        guard sample.state=="playing",let id=sample.musicPersistentID else { return }
        var identities:Set<String>=[id]
        // Music creates new URL-track IDs for catalog insertions. Match only
        // against our own ledger, with complete metadata and one unique result.
        if !knownIDs.contains(id),sample.albumMetadata["track_class"] as? String == "urlTrack" {
            let matches=metadata.filter{$0.value.matches(sample)}.map{$0.key}
            guard matches.count==1 else { return }
            identities.insert(matches[0])
        }
        if !albumIDs.isDisjoint(with:identities) { return }
        guard let index=songs.firstIndex(where:{!$0.isDisjoint(with:identities)}) else {
            // Existing user-queued music can precede our songs. Wait until
            // one of our known songs appears without growing an unrelated queue.
            return
        }
        let playing=songs[index]
        if waitingForAlbum {
            waitingForAlbum=false;observedIDs=playing;pendingReplacements=1;return
        }
        guard observedIDs.isDisjoint(with:playing) else { return }
        // Count one actual departure, never inferred skips from a queue index.
        // Music or the user can reorder songs; that must not create refill debt.
        if !observedIDs.isEmpty,songs.contains(where:{!$0.isDisjoint(with:observedIDs)}) {
            let departed=observedIDs
            songs.removeAll(where:{!$0.isDisjoint(with:departed)})
            pendingReplacements += 1
        }
        observedIDs=playing
    }
}
