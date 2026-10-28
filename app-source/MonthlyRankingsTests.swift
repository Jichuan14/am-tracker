import Foundation

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw AppError(message: "Monthly ranking test: " + message) }
}

func monthlyRankingTests() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    func date(_ text: String) -> Date { parsedDate(text)! }
    let march = date("2026-03-15T12:00:00-07:00")
    func listen(_ id: String, _ track: String, _ at: String?, seconds: Double = 90,
                title: String = "Song", artist: String = "Artist", album: String = "Album", albumArtist: String = "Album artist") -> MonthlyListen {
        MonthlyListen(id: id, trackID: track, title: title, artist: artist, album: album,
                      albumArtist: albumArtist, observedAt: at.map(date), seconds: seconds)
    }
    let snapshot = MonthlySnapshot(listens: [
        listen("a1", "a", "2026-03-01T00:00:00-08:00", title: "A"),
        listen("a2", "a", "2026-03-08T03:01:00-07:00", title: "A"),
        listen("b1", "b", "2026-03-31T23:59:59-07:00", seconds: 500, title: "B"),
        listen("b2", "b", "2026-03-15T12:00:00-07:00", seconds: 0, title: "B"),
        listen("c1", "c", "2026-03-12T12:00:00-07:00", title: "C", artist: "Other", albumArtist: "Other"),
        listen("old1", "b", "2026-02-28T23:59:59-08:00", title: "B"),
        listen("old2", "b", "2026-02-10T12:00:00-08:00", title: "B"),
        listen("old3", "a", "2026-02-11T12:00:00-08:00", title: "A"),
        listen("future", "future", "2026-04-01T00:00:00-07:00"),
        listen("undated", "import", nil, seconds: 99999)
    ])
    let report = snapshot.report(month: march, category: .songs, metric: .entries, calendar: calendar)
    try check(report.entryCount == 5 && report.songCount == 3 && report.artistCount == 2, "monthly totals count dated entries and distinct identities")
    try check(report.seconds == 770 && report.undatedCount == 1, "observed time excludes undated history and respects local month boundaries and DST")
    try check(report.rows.map(\.rank) == [1, 1, 3], "equal entry counts share competition ranks with stable ordering")
    try check(report.rows[0].id == "a" && report.rows[0].previousRank == 2 && report.rows[0].movement == "↑ 1", "movement compares the preceding calendar month")
    try check(report.rows[2].movement == "New", "new means absent from the preceding month with recorded data")
    try check(report.rows.filter { $0.matches("B") }.first?.rank == 1, "search preserves the original monthly rank")
    let time = snapshot.report(month: march, category: .songs, metric: .time, calendar: calendar)
    try check(time.rows.first?.id == "b" && time.rows.map(\.rank) == [1, 2, 3], "listening-time ranking uses observed seconds rather than duration or entry count")
    let artists = snapshot.report(month: march, category: .artists, metric: .entries, calendar: calendar)
    try check(artists.rows.count == 2 && artists.rows.first?.entries == 4, "artist totals combine album artist credits")
    let albums = snapshot.report(month: march, category: .albums, metric: .entries, calendar: calendar)
    try check(albums.rows.count == 2 && albums.rows.first?.entries == 4, "albums combine tracks only under the same known album artist")
    let collaborations = MonthlySnapshot(listens: [
        listen("solo", "solo", "2026-03-01T12:00:00-08:00", seconds: 90, title: "Memória", artist: "ROSALÍA", album: "LUX", albumArtist: "ROSALÍA"),
        listen("guests", "guests", "2026-03-02T12:00:00-08:00", seconds: 150, title: "La Rumba Del Perdón", artist: "ROSALÍA, Estrella Morente & Sílvia Pérez Cruz", album: "LUX", albumArtist: "ROSALÍA"),
        listen("other-guests", "other-guests", "2026-03-03T12:00:00-08:00", seconds: 180, title: "Berghain", artist: "ROSALÍA, Björk & Yves Tumor", album: "LUX", albumArtist: "ROSALÍA"),
        listen("other-artist", "other-artist", "2026-03-04T12:00:00-08:00", seconds: 240, artist: "Estrella Morente", albumArtist: "Estrella Morente"),
        listen("prior-guest", "prior-guest", "2026-02-10T12:00:00-08:00", artist: "ROSALÍA & Guest", albumArtist: "ROSALÍA"),
        listen("prior-other-1", "prior-other-1", "2026-02-11T12:00:00-08:00", artist: "Estrella Morente", albumArtist: "Estrella Morente"),
        listen("prior-other-2", "prior-other-2", "2026-02-12T12:00:00-08:00", artist: "Estrella Morente", albumArtist: "Estrella Morente")
    ])
    let albumArtists = collaborations.report(month: march, category: .artists, metric: .entries, calendar: calendar)
    try check(albumArtists.rows.count == 2 && albumArtists.artistCount == 2, "solo and guest credits on ROSALÍA albums form one album-artist group")
    let rosalia = albumArtists.rows.first!
    try check(rosalia.title == "ROSALÍA" && rosalia.entries == 3 && rosalia.seconds == 420, "album-artist grouping combines entry counts and observed time")
    try check(rosalia.previousRank == 2 && rosalia.movement == "↑ 1", "previous-month movement uses the same album-artist grouping")
    let artistTime = collaborations.report(month: march, category: .artists, metric: .time, calendar: calendar)
    try check(artistTime.rows.first?.title == "ROSALÍA" && artistTime.rows.first?.seconds == 420, "time-ranked artist charts combine collaborations")
    let collaborationSongs = collaborations.report(month: march, category: .songs, metric: .entries, calendar: calendar)
    try check(collaborationSongs.rows.first { $0.id == "guests" }?.subtitle == "ROSALÍA · LUX", "recap song labels use the album artist")
    try check(collaborationSongs.entryCount == 4 && collaborationSongs.songCount == 4 && collaborationSongs.seconds == 660, "artist grouping preserves song identities and listening totals")
    let artistCSV = monthlyCSV(albumArtists, category: .artists, metric: .entries, calendar: calendar)
    try check(!artistCSV.contains("Sílvia Pérez Cruz") && artistCSV.contains("ROSALÍA"), "artist CSV exports the grouped album artist")
    let fallbackArtists = MonthlySnapshot(listens: [
        listen("fallback", "fallback", "2026-03-01T12:00:00-08:00", artist: "Simon & Garfunkel", albumArtist: "  "),
        listen("album-only", "album-only", "2026-03-02T12:00:00-08:00", artist: "", albumArtist: "ROSALÍA")
    ]).report(month: march, category: .artists, metric: .entries, calendar: calendar)
    try check(Set(fallbackArtists.rows.map(\.title)) == ["ROSALÍA", "Simon & Garfunkel"] && fallbackArtists.artistCount == 2, "missing album artist falls back to intact song credits without splitting names")

    let empty = snapshot.report(month: date("2026-01-01T00:00:00-08:00"), category: .songs, metric: .entries, calendar: calendar)
    try check(empty.rows.isEmpty && empty.entryCount == 0 && empty.seconds == 0, "empty months have honest zero totals")
    let february = snapshot.report(month: date("2026-02-01T00:00:00-08:00"), category: .songs, metric: .entries, calendar: calendar)
    try check(february.rows.allSatisfy { $0.movement == "—" && !$0.hasPreviousData }, "missing previous data never implies a debut or upward movement")
    let unknown = MonthlySnapshot(listens: [
        listen("u1", "u1", "2026-03-01T12:00:00-08:00", title: "Same", artist: "", albumArtist: ""),
        listen("u2", "u2", "2026-03-01T12:00:00-08:00", title: "Same", artist: "", albumArtist: "")
    ])
    try check(unknown.report(month: march, category: .songs, metric: .entries, calendar: calendar).rows.count == 2, "same-titled song versions keep their own identities")
    try check(unknown.report(month: march, category: .albums, metric: .entries, calendar: calendar).rows.count == 2, "unknown album artists do not merge unrelated albums")
    try check(unknown.report(month: march, category: .artists, metric: .entries, calendar: calendar).artistCount == 0, "unknown artist credits do not inflate known artist totals")
    let december = date("2025-12-31T23:59:59-08:00")
    let january = date("2026-01-01T00:00:00-08:00")
    let rollover = MonthlySnapshot(listens: [listen("d", "a", stamp(december)), listen("j", "a", stamp(january))])
    try check(rollover.report(month: january, category: .songs, metric: .entries, calendar: calendar).rows.first?.previousRank == 1, "previous-month comparison crosses year boundaries")
    let unsafe = MonthlySnapshot(listens: [listen("csv", "csv", "2026-03-01T12:00:00-08:00", title: "=SUM(1,2)\n\"title\"")])
    let csv = monthlyCSV(unsafe.report(month: march, category: .songs, metric: .entries, calendar: calendar), category: .songs, metric: .entries, calendar: calendar)
    try check(csv.contains("2026-03") && csv.contains("\"'=SUM(1,2)\n\"\"title\"\"\"") && csv.contains("previous_rank"), "CSV uses local month, escapes quotes and line breaks, and guards spreadsheet formulas")
    try check(monthlyDuration(0) == "0m" && monthlyDuration(15) == "<1m" && monthlyDuration(3661) == "1h 1m", "duration labels distinguish sub-minute observation from no time")

    let payload = snapshot.recapPayload(month: march, metric: .entries, recording: true, now: march, calendar: calendar)
    try check(payload["minutes"] as? Int == 12 && payload["entries"] as? Int == 5, "recap highlights use observed time and canonical entry counts")
    try check(payload["current"] as? Bool == true && payload["recording"] as? Bool == true, "current month and recording status travel separately")
    let days = payload["days"] as! [[String: Any]]
    try check(days.count == 31 && days[0]["entries"] as? Int == 1 && days[30]["entries"] as? Int == 1, "recap daily activity uses local dates through DST")
    try check(days[30]["future"] as? Bool == true && payload["activeDays"] as? Int == 5, "recap includes a full month and distinguishes upcoming days")
    try check(JSONSerialization.isValidJSONObject(payload), "recap payload is bridge-safe JSON")
    let paused = snapshot.recapPayload(month: march, metric: .time, recording: false, now: march, calendar: calendar)
    try check(paused["recording"] as? Bool == false && (paused["songs"] as? [[String: Any]])?.first?["id"] as? String == "b", "recap time ordering and recording-off data remain available")
    let emptyPayload = MonthlySnapshot().recapPayload(month: march, metric: .entries, recording: false, now: march, calendar: calendar)
    try check(emptyPayload["entries"] as? Int == 0 && (emptyPayload["songs"] as? [[String: Any]])?.isEmpty == true, "empty recap sends real zeroes without sample music")

    let la = MonthlySnapshot.localCalendar(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    let honolulu = MonthlySnapshot.localCalendar(timeZone: TimeZone(identifier: "Pacific/Honolulu")!)
    let october = MonthlySnapshot.monthStart(date("2026-10-15T12:00:00Z"), calendar: la)
    let rebased = MonthlySnapshot.rebasedMonth(october, from: la, to: honolulu)
    try check(honolulu.component(.month, from: october) == 9, "time-zone regression fixture crosses the local month boundary")
    try check(honolulu.component(.month, from: rebased) == 10 && rebased == MonthlySnapshot.monthStart(rebased, calendar: honolulu), "selected civil month survives a westward time-zone change")
    let prior = honolulu.date(byAdding: .month, value: -1, to: rebased)!
    try check(honolulu.date(byAdding: .month, value: 1, to: prior) == rebased, "previous/next remain anchored to month starts after changing zones")
    let exportFixture = MonthlySnapshot(listens: [listen("export-zone", "zone", "2026-10-15T12:00:00Z")])
    let exportReport = exportFixture.report(month: october, category: .songs, metric: .entries, calendar: la)
    let fixedExport = monthlyCSV(exportReport, category: .songs, metric: .entries, calendar: la)
    let changedExport = monthlyCSV(exportReport, category: .songs, metric: .entries, calendar: honolulu)
    try check(fixedExport.contains("2026-10") && changedExport.contains("2026-09"), "exports retain their captured calendar when the system zone changes while saving")
    for locale in ["en_US@calendar=chinese", "en_US@calendar=hebrew", "th_TH@calendar=buddhist"] {
        let local = MonthlySnapshot.localCalendar(timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: locale))
        try check(local.identifier == .gregorian, "non-Gregorian system preferences cannot change chart month identity")
        let july = MonthlySnapshot().recapPayload(month: date("2025-07-01T12:00:00Z"), metric: .entries, recording: false, now: date("2026-10-15T12:00:00Z"), calendar: local)
        let august = MonthlySnapshot().recapPayload(month: date("2025-08-01T12:00:00Z"), metric: .entries, recording: false, now: date("2026-10-15T12:00:00Z"), calendar: local)
        try check(july["month"] as? String == "2025-07" && august["month"] as? String == "2025-08", "leap-calendar preferences cannot collide month keys")
        try check(july["year"] as? Int == 2025 && july["monthNumber"] as? Int == 7, "recap year/month fields agree with Gregorian CSV keys")
    }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("am-track-monthly-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let archive = try Archive(folder: folder)
    try archive.exec("INSERT INTO sessions(persistent_id,title,artist,album,first_observed_at,last_observed_at,ended_at,observed_listening_seconds,duration) VALUES (?,?,?,?,?,?,?,?,?)",
                     ["0000000000000001", "Recorded", "Artist", "Album", stamp(march), stamp(march.addingTimeInterval(120)), stamp(march.addingTimeInterval(120)), 120, 240])
    try archive.syncRecordingsAndLibrary()
    let track = try archive.rows("SELECT track_id FROM recording_tracks").first!["track_id"]!
    try archive.exec("INSERT INTO track_aliases VALUES ('catalog','123456',?)", [track])
    try archive.exec("INSERT INTO track_aliases VALUES ('catalog','654321',?)", [track])
    var imported = ImportedSong(title: "Undated"); imported.persistentID = "0000000000000002"
    _ = try archive.ingest(HistorySnapshot(hash: "monthly-import", songs: [imported], source: folder.appendingPathComponent("History.dat"), modified: stamp(march), captured: march))
    try archive.syncRecordingsAndLibrary()
    let stored = try archive.monthlySnapshot().report(month: march, category: .songs, metric: .entries, calendar: calendar)
    try check(stored.entryCount == 1 && stored.seconds == 120 && stored.undatedCount == 1, "archive query deduplicates catalog aliases and never assigns import timestamps to listens")
    try archive.saveAlbumMetadata(["album_artist": "ROSALÍA", "album": "Album"], id: track)
    let albumArtistSnapshot = try archive.monthlySnapshot()
    try check(albumArtistSnapshot.listens.first { $0.trackID == track }?.artist == "Artist", "album-artist grouping preserves the recorded song credits")
    let storedArtists = albumArtistSnapshot.report(month: march, category: .artists, metric: .entries, calendar: calendar)
    try check(storedArtists.rows.first?.title == "ROSALÍA" && storedArtists.rows.first?.entries == 1, "archive album metadata drives the artist ranking")
    try archive.exec("UPDATE listening_history SET status='superseded' WHERE track_id=?", [track])
    try check(try archive.monthlySnapshot().report(month: march, category: .songs, metric: .entries, calendar: calendar).entryCount == 0, "superseded recorder evidence cannot leak into monthly rankings")
    print("PASS: monthly boundaries, DST, year rollover, ties, rank movement, categories, unknown identities, CSV safety, canonical deduplication and undated exclusions.")
}
