import Foundation

// Monthly charts use reconciled history identities, never library lifetime counts
// or the date on which an undated Music history snapshot was imported.
struct MonthlyListen: Equatable {
    let id: String
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let observedAt: Date?
    let seconds: Double
    var rankingArtist: String {
        let albumCredit = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        return albumCredit.isEmpty ? artist.trimmingCharacters(in: .whitespacesAndNewlines) : albumCredit
    }
}

enum MonthlyCategory: String, CaseIterable, Identifiable {
    case songs = "Songs", artists = "Artists", albums = "Albums"
    var id: String { rawValue }
    var column: String { self == .songs ? "Song" : self == .artists ? "Artist" : "Album" }
}

enum MonthlyMetric: String, CaseIterable, Identifiable {
    case entries = "Entries", time = "Listening time"
    var id: String { rawValue }
}

struct MonthlyRank: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let entries: Int
    let seconds: Double
    let rank: Int
    let previousRank: Int?
    let hasPreviousData: Bool
    var movement: String {
        guard hasPreviousData else { return "—" }
        guard let previousRank else { return "New" }
        let difference = previousRank - rank
        return difference == 0 ? "—" : "\(difference > 0 ? "↑" : "↓") \(abs(difference))"
    }
    var movementHelp: String {
        guard hasPreviousData else { return "No dated entries in the previous month to compare." }
        guard let previousRank else { return "No entry for this item in the previous month." }
        return "Previous month: #\(previousRank). Current month: #\(rank)."
    }
    func matches(_ search: String) -> Bool {
        search.isEmpty || (title + " " + subtitle).localizedCaseInsensitiveContains(search)
    }
}

struct MonthlyReport {
    let month: Date
    let rows: [MonthlyRank]
    let entryCount: Int
    let songCount: Int
    let artistCount: Int
    let seconds: Double
    let undatedCount: Int
}

struct MonthlySnapshot: Equatable {
    var listens: [MonthlyListen] = []
    // Charts and CSV keys use Gregorian months in the Mac's local time zone,
    // independent of calendars with leap months or more than twelve months.
    static func localCalendar(timeZone: TimeZone = .current, locale: Locale = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone; calendar.locale = locale
        return calendar
    }
    static var calendar: Calendar { localCalendar() }
    static func rebasedMonth(_ month: Date, from previous: Calendar, to calendar: Calendar) -> Date {
        var fields = previous.dateComponents([.year, .month], from: month)
        fields.day = 1
        return monthStart(calendar.date(from: fields) ?? month, calendar: calendar)
    }
    static func monthLabel(_ month: Date, calendar: Calendar, includeYear: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(includeYear ? "MMMM y" : "MMMM")
        return formatter.string(from: month)
    }
    var availableMonths: [Date] {
        Array(Set(listens.compactMap { $0.observedAt.map { Self.monthStart($0) } }))
            .filter { $0 <= Self.monthStart(Date()) }.sorted(by: >)
    }
    static func monthStart(_ date: Date, calendar: Calendar = MonthlySnapshot.calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }
    func report(month: Date, category: MonthlyCategory, metric: MonthlyMetric,
                calendar: Calendar = MonthlySnapshot.calendar) -> MonthlyReport {
        let start = Self.monthStart(month, calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        let previous = calendar.date(byAdding: .month, value: -1, to: start)!
        let current = listens.filter { guard let date = $0.observedAt else { return false }; return date >= start && date < end }
        let past = listens.filter { guard let date = $0.observedAt else { return false }; return date >= previous && date < start }
        let ranked = Self.groups(current, category: category, metric: metric)
        let oldRanks = Dictionary(uniqueKeysWithValues: Self.groups(past, category: category, metric: metric).map { ($0.id, $0.rank) })
        let rows = ranked.map { row in
            MonthlyRank(id: row.id, title: row.title, subtitle: row.subtitle, entries: row.entries, seconds: row.seconds,
                        rank: row.rank, previousRank: oldRanks[row.id], hasPreviousData: !past.isEmpty)
        }
        return MonthlyReport(month: start, rows: rows, entryCount: current.count,
            songCount: Set(current.map(\.trackID)).count,
            artistCount: Set(current.map { normalized($0.rankingArtist) }.filter { !$0.isEmpty }).count,
            seconds: current.reduce(0) { $0 + $1.seconds }, undatedCount: listens.filter { $0.observedAt == nil }.count)
    }
    private static func groups(_ listens: [MonthlyListen], category: MonthlyCategory, metric: MonthlyMetric) -> [MonthlyRank] {
        struct Group {
            let id: String
            let title: String
            let subtitle: String
            var entries = 0
            var seconds: Double = 0
        }
        var grouped: [String: Group] = [:]
        for listen in listens {
            let id: String, title: String, subtitle: String
            switch category {
            case .songs:
                id = listen.trackID; title = listen.title.isEmpty ? "Untitled song" : listen.title
                subtitle = [listen.rankingArtist.isEmpty ? "Unknown artist" : listen.rankingArtist, listen.album].filter { !$0.isEmpty }.joined(separator: " · ")
            case .artists:
                id = "artist:" + normalized(listen.rankingArtist)
                title = listen.rankingArtist.isEmpty ? "Unknown artist" : listen.rankingArtist; subtitle = ""
            case .albums:
                // Same-named albums by different artists remain separate. Missing
                // album identity stays track-specific rather than merging strangers.
                id = listen.album.isEmpty || listen.albumArtist.isEmpty ? "unknown-album:" + listen.trackID : "album:" + metadataKey("", listen.albumArtist, listen.album)
                title = listen.album.isEmpty ? "Unknown album" : listen.album
                subtitle = listen.albumArtist.isEmpty ? "Unknown album artist" : listen.albumArtist
            }
            var group = grouped[id] ?? Group(id: id, title: title, subtitle: subtitle)
            group.entries += 1; group.seconds += listen.seconds
            grouped[id] = group
        }
        let sorted = grouped.values.sorted { a, b in
            if metric == .entries, a.entries != b.entries { return a.entries > b.entries }
            if metric == .time, a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.title != b.title { return a.title < b.title }
            return a.id < b.id
        }
        var rank = 0
        return sorted.enumerated().map { index, group in
            if index == 0 || (metric == .entries ? group.entries != sorted[index - 1].entries : group.seconds != sorted[index - 1].seconds) { rank = index + 1 }
            return MonthlyRank(id: group.id, title: group.title, subtitle: group.subtitle, entries: group.entries,
                               seconds: group.seconds, rank: rank, previousRank: nil, hasPreviousData: false)
        }
    }
}

extension Archive {
    func monthlySnapshot() throws -> MonthlySnapshot {
        // GROUP BY canonical identity also prevents catalog aliases from multiplying
        // one listening entry in the unified view.
        let rows = try rows("""
            SELECT u.id,u.track_id,u.title,u.artist,u.album,u.first_observed_at,
                   u.observed_listening_seconds,m.album_artist
            FROM unified_history u LEFT JOIN track_album_metadata m ON m.track_id=u.track_id
            GROUP BY u.id ORDER BY u.id
            """)
        return MonthlySnapshot(listens: rows.map { row in
            let seconds = Double(row["observed_listening_seconds"] ?? "") ?? 0
            return MonthlyListen(id: row["id"]!, trackID: row["track_id"]!, title: row["title"] ?? "",
                artist: row["artist"] ?? "", album: row["album"] ?? "", albumArtist: row["album_artist"] ?? "",
                observedAt: parsedDate(row["first_observed_at"]), seconds: seconds.isFinite ? max(0, seconds) : 0)
        })
    }
}

func monthlyDuration(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds) / 60)
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    if seconds > 0 && minutes == 0 { return "<1m" }
    return "\(minutes)m"
}

func monthlyCSV(_ report: MonthlyReport, category: MonthlyCategory, metric: MonthlyMetric, calendar: Calendar = MonthlySnapshot.calendar) -> String {
    func escape(_ text: String) -> String {
        var value = text
        if let first = value.drop(while: { $0 == " " }).first, "=+-@\t\r\n".contains(first) { value = "'" + value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    let parts = calendar.dateComponents([.year, .month], from: report.month)
    let month = String(format: "%04d-%02d", parts.year!, parts.month!)
    let header = ["month", "category", "ranked_by", "rank", "title", "detail", "entries", "observed_seconds", "previous_rank"]
    let lines = report.rows.map { row in
        [month, category.rawValue, metric.rawValue, String(row.rank), row.title, row.subtitle,
         String(row.entries), String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), row.seconds), row.previousRank.map(String.init) ?? ""].map(escape).joined(separator: ",")
    }
    return "\u{FEFF}" + ([header.joined(separator: ",")] + lines).joined(separator: "\r\n") + "\r\n"
}
