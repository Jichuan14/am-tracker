import Foundation

private struct SequenceRun {
    let track:String
    var positions:[Int]
}
private func runs(_ tracks:[String]) -> [SequenceRun] {
    var result:[SequenceRun]=[]
    for (i,track) in tracks.enumerated() {
        if result.last?.track==track { result[result.count-1].positions.append(i) }
        else { result.append(SequenceRun(track:track,positions:[i])) }
    }
    return result
}

extension Archive {
    func createUnifiedSchema() throws {
        try transaction {
            try exec("""
                CREATE TABLE listening_history (
                    id TEXT PRIMARY KEY, track_id TEXT NOT NULL REFERENCES music_tracks(id),
                    music_order INTEGER UNIQUE, music_snapshot_id INTEGER REFERENCES history_snapshots(id), music_ordinal INTEGER,
                    status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','superseded')),
                    superseded_by_snapshot INTEGER REFERENCES history_snapshots(id),note TEXT NOT NULL DEFAULT '')
                """)
            try exec("CREATE TABLE history_recordings (session_id INTEGER PRIMARY KEY REFERENCES sessions(id),history_id TEXT NOT NULL REFERENCES listening_history(id),method TEXT NOT NULL)")
            try exec("""
                CREATE TABLE history_observations (
                    snapshot_id INTEGER NOT NULL,ordinal INTEGER NOT NULL,history_id TEXT NOT NULL REFERENCES listening_history(id),
                    PRIMARY KEY(snapshot_id,ordinal),UNIQUE(snapshot_id,history_id),
                    FOREIGN KEY(snapshot_id,ordinal) REFERENCES history_items(snapshot_id,ordinal))
                """)
            try exec("CREATE INDEX recordings_history ON history_recordings(history_id)")
            try exec("CREATE INDEX observations_history ON history_observations(history_id)")
            try exec("""
                CREATE VIEW unified_history AS
                WITH recorded AS (
                    SELECT e.history_id,COUNT(*) recording_segments,MIN(s.first_observed_at) first_observed_at,
                        MAX(s.last_observed_at) last_observed_at,MAX(s.last_listening_at) last_listening_at,
                        CASE WHEN COUNT(s.ended_at)=COUNT(*) THEN MAX(s.ended_at) END ended_at,
                        SUM(s.observed_listening_seconds) observed_listening_seconds,MAX(s.duration) duration,
                        GROUP_CONCAT(s.id) recording_ids,GROUP_CONCAT(DISTINCT e.method) match_method
                    FROM history_recordings e JOIN sessions s ON s.id=e.session_id GROUP BY e.history_id)
                SELECT h.id,h.track_id,t.title,t.artist,t.album,t.genre,a.value catalog_id,
                    CASE WHEN h.music_order IS NOT NULL AND r.history_id IS NOT NULL THEN 'Music + recording'
                         WHEN h.music_order IS NOT NULL THEN 'Music history' ELSE 'Recording' END source,
                    h.music_order,h.music_snapshot_id,h.music_ordinal,p.captured_at history_checked_at,
                    r.first_observed_at,r.last_observed_at,r.last_listening_at,r.ended_at,
                    r.observed_listening_seconds,COALESCE(r.duration,t.duration) duration,
                    r.recording_ids,COALESCE(r.recording_segments,0) recording_segments,r.match_method,h.note
                FROM listening_history h JOIN music_tracks t ON t.id=h.track_id
                LEFT JOIN recorded r ON r.history_id=h.id
                LEFT JOIN history_snapshots p ON p.id=h.music_snapshot_id
                LEFT JOIN track_aliases a ON a.track_id=h.track_id AND a.kind='catalog'
                WHERE h.status='active'
                """)
            try exec("PRAGMA user_version=3")
        }
    }

    /// No external file access. Raw evidence is retained in this same SQLite file.
    /// Only an explicit import/check (or the one-time migration of existing data)
    /// makes Music's sequence authoritative over overlapping recordings.
    func syncUnifiedHistory(preferMusic:Bool=false) throws {
        try transaction {
            for row in try rows("SELECT r.* FROM recording_tracks r LEFT JOIN history_recordings e ON e.session_id=r.session_id WHERE e.session_id IS NULL ORDER BY r.session_id") {
                let session=Int(row["session_id"]!)!,id="r:\(session)"
                try exec("INSERT OR IGNORE INTO listening_history(id,track_id) VALUES (?,?)",[id,row["track_id"]])
                try exec("INSERT INTO history_recordings VALUES (?,?,?)",[session,id,"recorded"])
            }
            // Process every stored snapshot in order once, not only the latest one.
            let pending=try rows("SELECT p.* FROM history_snapshots p WHERE NOT EXISTS (SELECT 1 FROM history_observations o WHERE o.snapshot_id=p.id) AND p.entry_count>0 ORDER BY p.id")
            for snapshot in pending {
                let sid=Int(snapshot["id"]!)!
                let items=try rows("SELECT * FROM history_items WHERE snapshot_id=? ORDER BY ordinal",[sid])
                let previous=try rows("SELECT p.id FROM history_snapshots p WHERE p.id<? AND EXISTS(SELECT 1 FROM history_observations o WHERE o.snapshot_id=p.id) ORDER BY p.id DESC LIMIT 1",[sid]).first
                let old=try previous.map { try rows("SELECT o.history_id,h.track_id FROM history_observations o JOIN listening_history h ON h.id=o.history_id WHERE o.snapshot_id=? ORDER BY o.ordinal",[Int($0["id"]!)!]) } ?? []
                let keys=items.map{$0["track_id"]!},oldKeys=old.map{$0["track_id"]!}
                var overlap=0
                if keys==oldKeys { overlap=keys.count }
                else if min(keys.count,oldKeys.count)>=3 {
                    let possible=(3...min(keys.count,oldKeys.count)).filter { Array(oldKeys.suffix($0))==Array(keys.prefix($0)) }
                    if possible.count==1,let n=possible.first,Set(keys.prefix(n)).count>=2 { overlap=n }
                }
                var order=Int(try rows("SELECT COALESCE(MAX(music_order),0) n FROM listening_history").first!["n"]!)!
                for (i,item) in items.enumerated() {
                    var target:String?
                    if i<overlap { target=old[old.count-overlap+i]["history_id"] }
                    if target==nil,let occurrence=item["occurrence_id"] {
                        target=try rows("SELECT o.history_id FROM history_observations o JOIN history_items i ON i.snapshot_id=o.snapshot_id AND i.ordinal=o.ordinal WHERE i.occurrence_id=? LIMIT 1",[Int(occurrence)!]).first?["history_id"]
                    }
                    if target==nil {
                        let id="m:\(sid):\(i)";order += 1;target=id
                        let note=old.isEmpty || overlap>0 ? "" : "Earlier snapshots retained; overlap could not be established."
                        try exec("INSERT INTO listening_history(id,track_id,music_order,music_snapshot_id,music_ordinal,note) VALUES (?,?,?,?,?,?)",[id,item["track_id"],order,sid,i,note])
                    }
                    try exec("INSERT INTO history_observations VALUES (?,?,?)",[sid,i,target])
                }
            }
            // Empty snapshots are valid checks and never erase the archive.
            let first=try value("unified_initialized").isEmpty
            if preferMusic || first,let snapshot=try rows("SELECT * FROM history_snapshots WHERE id=CAST((SELECT value FROM metadata WHERE key='history_current_snapshot') AS INTEGER)").first {
                try applyMusicPriority(snapshot)
                try meta("unified_last_music_priority_check",stamp())
            }
            try meta("unified_initialized","yes")
        }
    }

    private func applyMusicPriority(_ snapshot:[String:String]) throws {
        let sid=Int(snapshot["id"]!)!
        let music=try rows("SELECT o.history_id,h.track_id FROM history_observations o JOIN listening_history h ON h.id=o.history_id WHERE o.snapshot_id=? ORDER BY o.ordinal",[sid])
        guard !music.isEmpty else { return }
        // Do not merge recordings made after this file version was first observed.
        let recordings=try rows("SELECT s.*,r.track_id,e.history_id FROM sessions s JOIN recording_tracks r ON r.session_id=s.id JOIN history_recordings e ON e.session_id=s.id WHERE datetime(s.first_observed_at)<=datetime(?) ORDER BY datetime(s.first_observed_at),s.id",[snapshot["captured_at"]])
        let recordingRuns=runs(recordings.map{$0["track_id"]!}),musicRuns=runs(music.map{$0["track_id"]!})
        guard !recordingRuns.isEmpty,!musicRuns.isEmpty else { return }
        var pairs:[Int:Int]=[:]
        // Unique three-song contexts anchor the same stretch of listening. Start
        // from the earliest recording anchor so a later replay of an album cannot
        // pull newer recordings backwards into an older Music sequence.
        if min(recordingRuns.count,musicRuns.count)>=3 {
            let rk=recordingRuns.map{$0.track},mk=musicRuns.map{$0.track}
            func positions(_ needle:[String],_ haystack:[String]) -> [Int] {
                guard haystack.count>=needle.count else { return [] }
                return (0...haystack.count-needle.count).filter { Array(haystack[$0..<$0+needle.count])==needle }
            }
            var lastR = -1,lastM = -1
            for r in 0...rk.count-3 {
                let context=Array(rk[r..<r+3])
                let mp=positions(context,mk).filter { m in
                    if let known=pairs[r] { return m==known }
                    return r>lastR && m>lastM
                }
                guard positions(context,rk).count==1,mp.count==1,let m=mp.first else { continue }
                // Overlapping anchors must agree with the already established mapping.
                guard (r>lastR && m>lastM) || pairs[r]==m else { continue }
                for delta in 0..<3 {
                    if let known=pairs[r+delta],known != m+delta { continue }
                    pairs[r+delta]=m+delta
                }
                lastR=max(lastR,r+2);lastM=max(lastM,m+2)
            }
            // Within anchored boundaries, add only unique, order-consistent matches.
            let anchors=pairs.keys.sorted()
            if anchors.count>1 {
                for k in 1..<anchors.count {
                    let left=anchors[k-1],right=anchors[k],lo=pairs[left]!,hi=pairs[right]!
                    guard right>left+1,hi>lo+1 else { continue }
                    var cursor=lo+1
                    for r in left+1..<right {
                        let matches=(cursor..<hi).filter{musicRuns[$0].track==recordingRuns[r].track}
                        if matches.count==1 { pairs[r]=matches[0];cursor=matches[0]+1 }
                    }
                }
            }
        }
        // Retain the existing bounded-window matches as explicitly provisional.
        let live=try rows("SELECT m.session_id,o.history_id FROM history_matches m JOIN history_items i ON i.occurrence_id=m.occurrence_id JOIN history_observations o ON o.snapshot_id=i.snapshot_id AND o.ordinal=i.ordinal WHERE i.snapshot_id=?",[sid])
        var individual:[Int:String]=[:]
        for row in live { individual[Int(row["session_id"]!)!]=row["history_id"]! }
        if let first=pairs.keys.min(),let last=pairs.keys.max() {
            var r=first-1,m=pairs[first]!-1
            while r>=0 && m>=0 && recordingRuns[r].track==musicRuns[m].track { pairs[r]=m;r -= 1;m -= 1 }
            r=last+1;m=pairs[last]!+1
            while r<recordingRuns.count && m<musicRuns.count && recordingRuns[r].track==musicRuns[m].track { pairs[r]=m;r += 1;m += 1 }
        }
        let coveredStart=pairs.keys.min(),coveredEnd=pairs.keys.max()
        for (runIndex,run) in recordingRuns.enumerated() {
            if let musicIndex=pairs[runIndex] {
                let targets=musicRuns[musicIndex].positions
                // Music's number of occurrences takes precedence over recorder
                // fragments/replays in the covered run. Raw sessions remain intact.
                for (part,position) in run.positions.enumerated() {
                    let target=music[targets[min(part,targets.count-1)]]["history_id"]!
                    try attachRecording(Int(recordings[position]["id"]!)!,to:target,method:"Music sequence priority; recording time is an observation",snapshot:sid)
                }
            } else if let start=coveredStart,let end=coveredEnd,runIndex>start && runIndex<end {
                for position in run.positions {
                    let old=recordings[position]["history_id"]!
                    let backed=try rows("SELECT 1 FROM history_observations WHERE history_id=? LIMIT 1",[old])
                    // Do not discard an event supported by an older Music snapshot.
                    if backed.isEmpty {
                        try exec("UPDATE listening_history SET status='superseded',superseded_by_snapshot=?,note=? WHERE id=?",[sid,"Recorder-only entry inside a Music-covered sequence; Music takes priority.",old])
                    }
                }
            }
        }
        for (session,target) in individual {
            // A sequence anchor is stronger than the old provisional window match.
            let current=try rows("SELECT e.method FROM history_recordings e WHERE e.session_id=?",[session]).first?["method"] ?? ""
            if current=="recorded" { try attachRecording(session,to:target,method:"Likely same track within live check window",snapshot:sid) }
        }
    }

    private func attachRecording(_ session:Int,to target:String,method:String,snapshot:Int) throws {
        guard let old=try rows("SELECT e.history_id,r.track_id FROM history_recordings e JOIN recording_tracks r ON r.session_id=e.session_id WHERE e.session_id=?",[session]).first,
              let destination=try rows("SELECT * FROM listening_history WHERE id=?",[target]).first,old["track_id"]==destination["track_id"] else { throw AppError(message:"Cannot merge evidence for different songs.") }
        let prior=old["history_id"]!
        // Never move an already attached recording between two different Music plays.
        if prior != target {
            let backed=try rows("SELECT 1 FROM history_observations WHERE history_id=? LIMIT 1",[prior])
            if !backed.isEmpty { return }
        }
        try exec("UPDATE history_recordings SET history_id=?,method=? WHERE session_id=?",[target,method,session])
        try exec("UPDATE listening_history SET status='active',superseded_by_snapshot=NULL WHERE id=?",[target])
        if prior != target {
            try exec("UPDATE listening_history SET status='superseded',superseded_by_snapshot=?,note=? WHERE id=? AND NOT EXISTS (SELECT 1 FROM history_recordings WHERE history_id=?) AND NOT EXISTS (SELECT 1 FROM history_observations WHERE history_id=?)",[snapshot,"Merged into Music history; original recording retained as evidence.",prior,prior,prior])
        }
    }

    func unifiedRows() throws -> [[String:String]] {
        try rows("SELECT * FROM unified_history ORDER BY CASE WHEN first_observed_at IS NULL THEN 1 ELSE 0 END,datetime(first_observed_at) DESC,music_order DESC,id")
    }
    func exportUnifiedHistory() throws {
        try export("history.csv","SELECT * FROM unified_history ORDER BY CASE WHEN first_observed_at IS NULL THEN 1 ELSE 0 END,datetime(first_observed_at) DESC,music_order DESC,id",["id","title","artist","album","source","first_observed_at","last_observed_at","last_listening_at","ended_at","observed_listening_seconds","duration","music_order","history_checked_at","recording_ids","recording_segments","match_method","note","catalog_id","track_id"])
    }
    func auditUnifiedHistory() throws -> [String:Any] {
        let missingRecordings=try rows("SELECT s.id FROM sessions s LEFT JOIN history_recordings e ON e.session_id=s.id WHERE e.session_id IS NULL")
        let missingMusic=try rows("SELECT i.snapshot_id,i.ordinal FROM history_items i LEFT JOIN history_observations o ON o.snapshot_id=i.snapshot_id AND o.ordinal=i.ordinal WHERE o.history_id IS NULL")
        let wrongTracks=try rows("SELECT e.session_id FROM history_recordings e JOIN recording_tracks r ON r.session_id=e.session_id JOIN listening_history h ON h.id=e.history_id WHERE r.track_id<>h.track_id")
        let wrongMusic=try rows("SELECT i.ordinal FROM history_items i JOIN history_observations o ON o.snapshot_id=i.snapshot_id AND o.ordinal=i.ordinal JOIN listening_history h ON h.id=o.history_id WHERE i.track_id<>h.track_id")
        let orphan=try rows("SELECT h.id FROM listening_history h WHERE status='active' AND NOT EXISTS(SELECT 1 FROM history_recordings r WHERE r.history_id=h.id) AND NOT EXISTS(SELECT 1 FROM history_observations o WHERE o.history_id=h.id)")
        let good=missingRecordings.isEmpty && missingMusic.isEmpty && wrongTracks.isEmpty && wrongMusic.isEmpty && orphan.isEmpty
        return ["unified_ok":good,"unified_entries":try rows("SELECT COUNT(*) n FROM unified_history").first!["n"]!,"unified_missing_recordings":missingRecordings.count,"unified_missing_music":missingMusic.count,"unified_track_errors":wrongTracks.count+wrongMusic.count,"unified_orphans":orphan.count,"superseded_recording_entries":try rows("SELECT COUNT(*) n FROM listening_history WHERE status='superseded'").first!["n"]!]
    }
}
