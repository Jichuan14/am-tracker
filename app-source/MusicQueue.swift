import AppKit

struct CatalogQueueSong {
    let index:Int
    let persistentID:String
    let catalogID:String
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
        result.append(CatalogQueueSong(index:index,persistentID:pid,catalogID:catalog))
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

    mutating func start(queued:[[String]],currentID:String?=nil,albumIDs:Set<String>=[]) {
        self=AutomaticQueue()
        enabled=true;self.albumIDs=albumIDs;knownIDs=albumIDs;waitingForAlbum = !albumIDs.isEmpty
        if albumIDs.isEmpty,let currentID { songs.append([currentID]);knownIDs.insert(currentID) }
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
        if albumIDs.contains(id) { return }
        guard let index=songs.firstIndex(where:{$0.contains(id)}) else {
            // Existing user-queued music can precede our songs. Wait until
            // one of our known songs appears without growing an unrelated queue.
            return
        }
        waitingForAlbum=false
        // Keeping the current song in the ledger makes repeated polls idempotent.
        // Jumping past several known songs accounts for skips between polls.
        pendingReplacements += index
        songs.removeFirst(index)
    }
}
