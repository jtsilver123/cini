import Foundation
import Compression

/// Letterboxd / IMDb import pipeline:
///
///   .zip or .csv ─► parse ─► TMDB match (concurrent, year-aware) ─► queue
///
/// Accepts the actual Letterboxd export ZIP (watched.csv, ratings.csv,
/// watchlist.csv, diary.csv) or any single CSV (Letterboxd or IMDb shape).
/// Star ratings are never imported as scores — they only order the ranking
/// queue so users re-rank their favorites first.
enum LetterboxdImporter {

    struct ImportedTitle: Hashable {
        let title: String
        let year: Int?
        /// Letterboxd 0.5–5 stars or IMDb 1–10 normalized to 0–5.
        var rating: Double?
        var isWatchlist: Bool = false
        /// Lives only in a custom list — never enters the ranking queue
        /// or the watchlist.
        var isListOnly: Bool = false
        /// reviews.csv text — lands as the movie's note in Your Details.
        var review: String?
        /// "yyyy-MM-dd" from diary.csv / watched.csv — lands in the diary.
        var watchedOn: String?
        /// EVERY watch date seen across the export (diary rewatches are
        /// separate rows) — each becomes its own diary entry.
        var watchDates: Set<String> = []
        /// Marked in likes/films.csv (a Letterboxd favorite) — sorts to the
        /// front of the ranking queue so favorites get ranked first.
        var liked: Bool = false
        /// Netflix: the highest season number seen in the viewing history —
        /// carried into Currently Watching progress.
        var lastSeason: Int?
        /// Netflix: episodes watched RECENTLY (still mid-show) — routed to
        /// Currently Watching instead of the "rank it" queue, because the
        /// user hasn't finished it.
        var stillWatching: Bool = false
    }

    struct MatchedTitle: Identifiable, Hashable {
        let imported: ImportedTitle
        let movie: Movie
        var id: Int { movie.tmdbID }
    }

    /// A Letterboxd custom list, resolved to TMDB matches.
    struct ImportedList: Identifiable {
        let id = UUID()
        let name: String
        var matches: [MatchedTitle]
    }

    struct Result {
        var watched: [MatchedTitle] = []
        var watchlist: [MatchedTitle] = []
        /// Shows the user is mid-way through (recent Netflix activity) —
        /// marked as Currently Watching, NOT queued to rank.
        var stillWatching: [MatchedTitle] = []
        var unmatched: [ImportedTitle] = []
        var importedLists: [ImportedList] = []
        /// Matches that exist only for list membership.
        var listPool: [MatchedTitle] = []
        var totalParsed = 0
    }

    enum Progress {
        case reading
        case matching(done: Int, total: Int)
    }

    enum ImportError: LocalizedError {
        case unreadableFile
        case noTitlesFound

        var errorDescription: String? {
            switch self {
            case .unreadableFile: return "Couldn't read that file. Export from Letterboxd: Settings → Data → Export."
            case .noTitlesFound: return "No movie titles found — try a Letterboxd/IMDb export, or paste your list one title per line."
            }
        }
    }

    // MARK: - Entry point

    static func run(
        fileURL: URL,
        tmdb: TMDBService = .shared,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> Result {
        await onProgress(.reading)
        // Picker URLs are security-scoped and need access granted; files in our
        // own sandbox (e.g. a desktop-transfer download saved to tmp) are NOT
        // scoped and return false here — that's fine, only an actual read
        // failure is fatal. (Treating false as fatal broke the upload import.)
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else { throw ImportError.unreadableFile }

        var titles: [ImportedTitle]
        var lists: [(name: String, titles: [ImportedTitle])] = []
        if fileURL.pathExtension.lowercased() == "zip" || data.starts(with: [0x50, 0x4B]) {
            (titles, lists) = try parseZip(data)
        } else {
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { throw ImportError.unreadableFile }
            if isNetflixCSV(text) {
                // Netflix viewing history — episodes collapse to one show.
                titles = parseNetflix(text)
            } else {
                titles = parse(csv: text, assumeWatchlist: fileURL.lastPathComponent.lowercased().contains("watchlist"))
                if titles.isEmpty {
                    // Not a CSV export — treat it as a plain list of titles
                    // (an Apple Notes export, a .txt, whatever).
                    titles = parseFreeText(text)
                }
            }
        }

        titles = dedupe(titles)
        // List titles the user hasn't watched/saved still need a TMDB
        // match — flagged so they skip the queue and the watchlist.
        let known = Set(titles.map(key))
        var extras: [ImportedTitle] = []
        var extraKeys = Set<String>()
        for entry in lists.flatMap(\.titles)
        where !known.contains(key(entry)) && extraKeys.insert(key(entry)).inserted {
            var copy = entry
            copy.isListOnly = true
            extras.append(copy)
        }
        guard !titles.isEmpty || !extras.isEmpty else { throw ImportError.noTitlesFound }

        var result = try await match(titles: titles + extras, tmdb: tmdb, onProgress: onProgress)

        // Resolve each list's membership against everything matched.
        var movieByKey: [String: MatchedTitle] = [:]
        for matched in result.watched + result.watchlist + result.listPool {
            movieByKey[key(matched.imported)] = matched
        }
        result.importedLists = lists.compactMap { list in
            let matches = list.titles.compactMap { movieByKey[key($0)] }
            return matches.isEmpty ? nil : ImportedList(name: list.name, matches: matches)
        }
        return result
    }

    /// Pasted text (Apple Notes flow): copy the note, paste in Cini.
    static func runText(
        _ text: String,
        tmdb: TMDBService = .shared,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> Result {
        await onProgress(.reading)
        var titles = parse(csv: text)
        if titles.isEmpty { titles = parseFreeText(text) }
        titles = dedupe(titles)
        guard !titles.isEmpty else { throw ImportError.noTitlesFound }
        return try await match(titles: titles, tmdb: tmdb, onProgress: onProgress)
    }

    // MARK: - Free text (Apple Notes and friends)

    /// Parses a human movie list: one title per line, tolerating bullets,
    /// checkboxes, numbering, and years in "(2021)" / "- 2021" / ", 2021".
    static func parseFreeText(_ text: String) -> [ImportedTitle] {
        let headers: Set<String> = ["movies", "movies to watch", "watchlist", "to watch",
                                    "films", "film list", "movie list", "watch list"]
        var titles: [ImportedTitle] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // List decorations: bullets, dashes, checkboxes, "12." / "12)"
            line = line.replacingOccurrences(
                of: "^[-*\u{2022}\u{2023}\u{25E6}\u{2013}\u{2014}\u{25A2}\u{2610}\u{2611}\u{2705}\u{274F}]+\\s*",
                with: "", options: .regularExpression)
            line = line.replacingOccurrences(
                of: "^\\d{1,3}[.)]\\s+", with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2, line.count <= 120 else { continue }
            guard !headers.contains(line.lowercased()) else { continue }

            var year: Int?
            if let range = line.range(of: "[(\\[](19|20)\\d{2}[)\\]]\\s*$", options: .regularExpression) {
                year = Int(line[range].filter(\.isNumber))
                line = String(line[..<range.lowerBound])
            } else if let range = line.range(of: "[,\\-\u{2013}]\\s*(19|20)\\d{2}\\s*$", options: .regularExpression) {
                year = Int(line[range].filter(\.isNumber))
                line = String(line[..<range.lowerBound])
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013},.\t"))
            guard line.count >= 2 else { continue }
            titles.append(ImportedTitle(title: line, year: year))
        }
        return dedupe(titles)
    }

    // MARK: - ZIP container (native: central directory + Compression inflate)

    static func parseZip(_ data: Data) throws -> (titles: [ImportedTitle],
                                                   lists: [(name: String, titles: [ImportedTitle])]) {
        let entries = try ZipReader.entries(in: data)
        var titles: [ImportedTitle] = []
        // watched.csv is the full history; ratings/diary/reviews enrich it
        // (stars, precise watch dates, review text) and contribute any
        // films of their own that watched.csv missed.
        let wanted = ["watched.csv", "ratings.csv", "diary.csv", "reviews.csv", "watchlist.csv"]
        for name in wanted {
            guard let entry = entries.first(where: { $0.name.lowercased().hasSuffix(name) }),
                  let bytes = try? ZipReader.extract(entry, from: data),
                  let text = String(data: bytes, encoding: .utf8) else { continue }
            let parsed = parse(csv: text, assumeWatchlist: name == "watchlist.csv")
            switch name {
            case "ratings.csv", "diary.csv", "reviews.csv":
                // One film can appear many times here (diary rewatches) —
                // collect EVERY date, and the first non-empty rating/review.
                var extraByKey: [String: ImportedTitle] = [:]
                var datesByKey: [String: Set<String>] = [:]
                for entry in parsed {
                    let entryKey = key(entry)
                    if var existing = extraByKey[entryKey] {
                        if existing.rating == nil { existing.rating = entry.rating }
                        if existing.review == nil { existing.review = entry.review }
                        extraByKey[entryKey] = existing
                    } else {
                        extraByKey[entryKey] = entry
                    }
                    datesByKey[entryKey, default: []].formUnion(entry.watchDates)
                }
                titles = titles.map { title in
                    var copy = title
                    let titleKey = key(title)
                    if let extra = extraByKey[titleKey] {
                        if copy.rating == nil { copy.rating = extra.rating }
                        if copy.review == nil { copy.review = extra.review }
                    }
                    if let dates = datesByKey[titleKey], !dates.isEmpty, name != "ratings.csv" {
                        copy.watchDates.formUnion(dates)
                        // diary/reviews dates beat watched.csv's logged date.
                        copy.watchedOn = copy.watchDates.max()
                    }
                    return copy
                }
                // Plus any film these files know that watched.csv missed —
                // repeated rows collapse later in dedupe(), dates intact.
                let known = Set(titles.map(key))
                titles += parsed.filter { !known.contains(key($0)) }
            default:
                titles += parsed
            }
        }

        // Letterboxd "likes" (favorites) live in likes/films.csv — fold them
        // in so they're never lost: films already known get a "liked" boost to
        // the front of the queue, and any liked film watched.csv missed joins
        // the queue too (you can only like what you've watched).
        if let entry = entries.first(where: { $0.name.lowercased().hasSuffix("likes/films.csv") }),
           let bytes = try? ZipReader.extract(entry, from: data),
           let text = String(data: bytes, encoding: .utf8) {
            let liked = parse(csv: text)
            let likedKeys = Set(liked.map(key))
            titles = titles.map { t in
                var c = t
                if likedKeys.contains(key(t)) { c.liked = true }
                return c
            }
            let known = Set(titles.map(key))
            for l in liked where !known.contains(key(l)) {
                var c = l
                c.liked = true
                titles.append(c)
            }
        }

        // Custom lists ride in a lists/ folder, one CSV each.
        var lists: [(name: String, titles: [ImportedTitle])] = []
        for entry in entries
        where entry.name.lowercased().contains("lists/") && entry.name.lowercased().hasSuffix(".csv") {
            guard let bytes = try? ZipReader.extract(entry, from: data),
                  let text = String(data: bytes, encoding: .utf8) else { continue }
            let fallback = (entry.name as NSString).lastPathComponent
                .replacingOccurrences(of: ".csv", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .localizedCapitalized
            let list = parseList(csv: text, fallbackName: fallback)
            if !list.titles.isEmpty { lists.append(list) }
        }
        return (titles, lists)
    }

    /// One lists/<name>.csv: a metadata block (with the list's real name)
    /// then a Position,Name,Year,… entries block.
    static func parseList(csv text: String, fallbackName: String) -> (name: String, titles: [ImportedTitle]) {
        let rows = parseCSVRows(text)
        var name = fallbackName
        var entryHeader = -1
        for (index, row) in rows.enumerated() {
            let lower = row.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if lower.first == "date", let nameColumn = lower.firstIndex(of: "name"),
               rows.indices.contains(index + 1), rows[index + 1].indices.contains(nameColumn) {
                let candidate = rows[index + 1][nameColumn].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { name = candidate }
            }
            if lower.first == "position" { entryHeader = index; break }
        }
        guard entryHeader >= 0, rows.indices.contains(entryHeader) else { return (name, []) }
        let header = rows[entryHeader].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let titleColumn = header.firstIndex(of: "name") else { return (name, []) }
        let yearColumn = header.firstIndex(of: "year")
        let titles = rows.dropFirst(entryHeader + 1).compactMap { fields -> ImportedTitle? in
            guard fields.indices.contains(titleColumn) else { return nil }
            let title = fields[titleColumn].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let year = yearColumn.flatMap { fields.indices.contains($0) ? Int(fields[$0].prefix(4)) : nil }
            return ImportedTitle(title: title, year: year)
        }
        return (name, dedupe(titles))
    }

    private static func key(_ title: ImportedTitle) -> String {
        normalize(title.title) + "|" + (title.year.map(String.init) ?? "")
    }

    static func dedupe(_ titles: [ImportedTitle]) -> [ImportedTitle] {
        var indexByKey: [String: Int] = [:]
        var result: [ImportedTitle] = []
        // Watched entries win over watchlist duplicates; repeated rows of
        // the same film (diary rewatches) MERGE — every watch date kept.
        for title in titles.sorted(by: { !$0.isWatchlist && $1.isWatchlist }) {
            if let index = indexByKey[key(title)] {
                if result[index].rating == nil { result[index].rating = title.rating }
                if result[index].review == nil { result[index].review = title.review }
                if result[index].watchedOn == nil { result[index].watchedOn = title.watchedOn }
                result[index].watchDates.formUnion(title.watchDates)
                if title.liked { result[index].liked = true }
                if title.stillWatching { result[index].stillWatching = true }
                if let season = title.lastSeason,
                   season > (result[index].lastSeason ?? 0) {
                    result[index].lastSeason = season
                }
            } else {
                indexByKey[key(title)] = result.count
                result.append(title)
            }
        }
        return result
    }

    // MARK: - CSV (Letterboxd + IMDb shapes, header-driven)

    static func parse(csv: String, assumeWatchlist: Bool = false) -> [ImportedTitle] {
        let rows = parseCSVRows(csv)
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        // Letterboxd: Name/Year/Rating · IMDb: Title/Year/Your Rating/Title Type
        guard let titleIndex = columns.firstIndex(where: { $0 == "name" || $0 == "title" }) else { return [] }
        let yearIndex = columns.firstIndex { $0 == "year" }
        // "rating10" / "watcheddate" are Cini's own export headers
        // (Letterboxd accepts them too) — recognizing them makes the
        // export → import round trip lossless.
        let ratingIndex = columns.firstIndex { $0 == "rating" || $0 == "your rating" || $0 == "rating10" }
        let isTenScale = ratingIndex.map { columns[$0] == "rating10" } ?? false
        let typeIndex = columns.firstIndex { $0 == "title type" }
        let reviewIndex = columns.firstIndex { $0 == "review" }
        // diary/reviews carry "Watched Date"; watched.csv's "Date" is when
        // it was marked watched — both feed the diary. (Watchlist rows'
        // "Date" is just when it was saved, so it's ignored there.)
        let watchedDateIndex = columns.firstIndex { $0 == "watched date" || $0 == "watcheddate" }
            ?? (assumeWatchlist ? nil : columns.firstIndex { $0 == "date" || $0 == "date rated" })
        let isIMDb = columns.contains("const")

        return rows.dropFirst().compactMap { fields in
            guard fields.indices.contains(titleIndex) else { return nil }
            let title = fields[titleIndex].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            // IMDb exports carry a type column: keep movies and full
            // series (Cini ranks shows), drop episodes/games/shorts.
            if let typeIndex, fields.indices.contains(typeIndex) {
                let type = fields[typeIndex].lowercased()
                let keep = type.isEmpty || type.contains("movie") || type.contains("series")
                guard keep, !type.contains("episode") else { return nil }
            }
            let year = yearIndex.flatMap { fields.indices.contains($0) ? Int(fields[$0].prefix(4)) : nil }
            var rating = ratingIndex.flatMap { fields.indices.contains($0) ? Double(fields[$0]) : nil }
            if isIMDb || isTenScale, let r = rating { rating = r / 2 }   // 1–10 → 0.5–5
            var entry = ImportedTitle(title: title, year: year, rating: rating, isWatchlist: assumeWatchlist)
            if let reviewIndex, fields.indices.contains(reviewIndex) {
                let review = fields[reviewIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !review.isEmpty { entry.review = review }
            }
            if let watchedDateIndex, fields.indices.contains(watchedDateIndex) {
                let date = fields[watchedDateIndex].trimmingCharacters(in: .whitespaces)
                if date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                    entry.watchedOn = date
                    entry.watchDates = [date]
                }
            }
            return entry
        }
    }

    // MARK: - Netflix viewing history (CIN-25)

    /// Netflix exports `Title,Date`, with TV broken out per episode
    /// ("Show: Season 7: The Sponge"). Detect that shape so it routes to the
    /// Netflix parser instead of the Letterboxd/IMDb one.
    static func isNetflixCSV(_ text: String) -> Bool {
        guard let header = parseCSVRows(text).first else { return false }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return cols.contains("title") && cols.contains("date")
            && !cols.contains("name") && !cols.contains("year") && !cols.contains("const")
            && cols.count <= 3
    }

    /// Parse a Netflix viewing-history CSV. Collapses every episode of a show
    /// into a single title (Netflix lists each episode separately), keeping all
    /// watch dates, and parses Netflix's "M/d/yy" dates.
    static func parseNetflix(_ csv: String) -> [ImportedTitle] {
        let rows = parseCSVRows(csv)
        guard let header = rows.first else { return [] }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let titleIdx = cols.firstIndex(of: "title") else { return [] }
        let dateIdx = cols.firstIndex(of: "date")

        var byKey: [String: ImportedTitle] = [:]
        var order: [String] = []
        for fields in rows.dropFirst() {
            guard fields.indices.contains(titleIdx) else { continue }
            let raw = fields[titleIdx].trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let title = netflixShowTitle(raw)
            let k = normalize(title)
            guard !k.isEmpty else { continue }
            let date = dateIdx.flatMap { fields.indices.contains($0) ? netflixDate(fields[$0]) : nil }
            let season = netflixSeason(raw)
            if var existing = byKey[k] {
                if let date { existing.watchDates.insert(date); existing.watchedOn = existing.watchDates.max() }
                if let season, season > (existing.lastSeason ?? 0) { existing.lastSeason = season }
                byKey[k] = existing
            } else {
                var entry = ImportedTitle(title: title, year: nil)
                if let date { entry.watchDates = [date]; entry.watchedOn = date }
                entry.lastSeason = season
                byKey[k] = entry
                order.append(k)
            }
        }
        // A show watched RECENTLY is mid-flight, not finished: it belongs in
        // Currently Watching, not the "rank everything you've seen" queue.
        // 60 days matches how people binge — an older last-watch means the
        // show was finished (or abandoned), and ranking it is fair game.
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return order.compactMap { k in
            guard var entry = byKey[k] else { return nil }
            // Only shows (episode rows collapsed): a movie title never gets
            // a season, and single-view titles with no season stay movies.
            if entry.lastSeason != nil || entry.watchDates.count > 1,
               let last = entry.watchedOn.flatMap({ formatter.date(from: $0) }),
               last >= cutoff {
                entry.stillWatching = true
            }
            return entry
        }
    }

    /// The season number in a Netflix episode row: "Show: Season 7: Ep" → 7,
    /// "Show: Part 2: Ep" → 2, branded "Show 5: Ep" → 5. nil for movies.
    static func netflixSeason(_ raw: String) -> Int? {
        let segments = raw.components(separatedBy: ": ")
        guard segments.count >= 2 else { return nil }
        let label = segments[1].lowercased()
        for marker in ["season ", "series ", "volume ", "part ", "book ", "chapter "]
        where label.hasPrefix(marker) {
            let digits = label.dropFirst(marker.count).prefix { $0.isNumber }
            return Int(digits)
        }
        if label.hasPrefix("limited series") { return 1 }
        // Branded season: "Stranger Things 5" — trailing number, only when
        // this is unambiguously a series (3+ segments).
        if segments.count >= 3,
           let match = segments[0].range(of: #" (\d+)$"#, options: .regularExpression) {
            return Int(segments[0][match].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// "Show: Season 7: The Sponge" → "Show"; "Inception" → "Inception".
    /// A movie with a subtitle ("Noah Kahan: Out of Body") stays whole.
    static func netflixShowTitle(_ raw: String) -> String {
        let segments = raw.components(separatedBy: ": ")
        guard segments.count >= 2 else { return raw }
        // Show: Season: Episode (3+ parts) is unambiguously a series.
        if segments.count >= 3 { return segments[0] }
        // Two parts: only a series if the second looks like a season label.
        return netflixIsSeasonLabel(segments[1]) ? segments[0] : raw
    }

    private static func netflixIsSeasonLabel(_ s: String) -> Bool {
        let lower = s.lowercased()
        let markers = ["season ", "series ", "volume ", "part ", "book ",
                       "chapter ", "limited series", "collection"]
        if markers.contains(where: { lower.hasPrefix($0) }) { return true }
        // Branded season ending in a number, e.g. "Stranger Things 5".
        return s.range(of: #" \d+$"#, options: .regularExpression) != nil
    }

    private static func netflixDate(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // Netflix localizes the viewing-activity date to the account's region,
        // so a US export reads M/d/yy but others read d/M/yy (and some yyyy-MM-dd).
        // Try each; the title still imports as watched even if no date parses —
        // only the diary date is at stake.
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "yyyy-MM-dd"
        for format in ["M/d/yy", "d/M/yy", "yyyy-MM-dd", "M/d/yyyy", "d/M/yyyy"] {
            parser.dateFormat = format
            if let date = parser.date(from: t) { return out.string(from: date) }
        }
        return nil
    }

    /// RFC-4180-ish CSV: quoted fields, escaped quotes (""), newlines in quotes.
    static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let char = pending ?? iterator.next() {
            pending = nil
            switch char {
            case "\"":
                if inQuotes {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }   // escaped quote
                        else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    inQuotes = true
                }
            case "," where !inQuotes:
                endField()
            case "\r" where !inQuotes:
                continue
            // In Swift, "\r\n" is a single Character (grapheme cluster),
            // so CRLF files hit this case — not "\r" then "\n".
            case "\n" where !inQuotes, "\r\n" where !inQuotes:
                endRow()
            default:
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    // MARK: - TMDB matching (concurrent, year-aware scoring)

    static func normalize(_ title: String) -> String {
        title.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func bestMatch(for imported: ImportedTitle, in candidates: [Movie]) -> Movie? {
        let target = normalize(imported.title)
        var best: (movie: Movie, score: Int)?
        for (index, movie) in candidates.prefix(8).enumerated() {
            var score = 0
            let candidate = normalize(movie.title)
            if candidate == target { score += 4 }
            else if candidate.contains(target) || target.contains(candidate) { score += 1 }
            if let wantYear = imported.year, let gotYear = movie.releaseYear {
                if wantYear == gotYear { score += 3 }
                else if abs(wantYear - gotYear) <= 1 { score += 2 }
                else if abs(wantYear - gotYear) > 3 { score -= 2 }
            }
            score += max(0, 2 - index)   // TMDB popularity order as tiebreak
            if best == nil || score > best!.score { best = (movie, score) }
        }
        guard let best, best.score >= 3 else { return nil }
        return best.movie
    }

    static func match(
        titles: [ImportedTitle],
        tmdb: TMDBService,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> Result {
        var result = Result()
        result.totalParsed = titles.count
        let total = titles.count
        var done = 0

        // Bounded concurrency: 10 in flight is still gentle on TMDB (their
        // limit is ~50 req/s) and roughly halves a 1,500-film library's
        // matching time vs the old 5.
        try await withThrowingTaskGroup(of: (ImportedTitle, Movie?).self) { group in
            var iterator = titles.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let next = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    let primary = (try? await tmdb.search(query: next.title, year: next.year)) ?? []
                    var match = bestMatch(for: next, in: primary)
                    if match == nil, next.year != nil {
                        let fallback = (try? await tmdb.search(query: next.title)) ?? []
                        match = bestMatch(for: next, in: fallback)
                    }
                    return (next, match)
                }
            }

            for _ in 0..<10 { addNext() }
            while inFlight > 0 {
                guard let (imported, movie) = try await group.next() else { break }
                inFlight -= 1
                done += 1
                if let movie {
                    let matched = MatchedTitle(imported: imported, movie: movie)
                    if imported.isListOnly { result.listPool.append(matched) }
                    else if imported.isWatchlist { result.watchlist.append(matched) }
                    else { result.watched.append(matched) }
                } else if !imported.isListOnly {
                    result.unmatched.append(imported)
                }
                await onProgress(.matching(done: done, total: total))
                addNext()
            }
        }

        // Favorites first: liked films lead, then by old rating, then recency.
        result.watched.sort {
            ($0.imported.liked ? 1 : 0, $0.imported.rating ?? -1, $0.movie.releaseYear ?? 0)
                > ($1.imported.liked ? 1 : 0, $1.imported.rating ?? -1, $1.movie.releaseYear ?? 0)
        }
        return result
    }
}

// MARK: - Minimal ZIP reader (stored + deflate entries)

enum ZipReader {
    struct Entry {
        let name: String
        let method: UInt16          // 0 = stored, 8 = deflate
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: Error { case malformed, unsupported }

    static func entries(in data: Data) throws -> [Entry] {
        // Locate End of Central Directory (scan tail for 0x06054b50).
        let tailStart = max(0, data.count - 66_000)
        var eocd: Int?
        if data.count >= 22 {
            var i = data.count - 22
            while i >= tailStart {
                if u32(data, i) == 0x06054b50 { eocd = i; break }
                i -= 1
            }
        }
        guard let eocd else { throw ZipError.malformed }

        let count = Int(u16(data, eocd + 10))
        var offset = Int(u32(data, eocd + 16))
        var result: [Entry] = []

        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(data, offset) == 0x02014b50 else { throw ZipError.malformed }
            let method = u16(data, offset + 10)
            let compressed = Int(u32(data, offset + 20))
            let uncompressed = Int(u32(data, offset + 24))
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            let localOffset = Int(u32(data, offset + 42))
            // A corrupt name length must fail cleanly, not crash the slice.
            guard offset + 46 + nameLength <= data.count else { throw ZipError.malformed }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            result.append(Entry(name: name, method: method, compressedSize: compressed,
                                uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let base = entry.localHeaderOffset
        guard base + 30 <= data.count, u32(data, base) == 0x04034b50 else { throw ZipError.malformed }
        let nameLength = Int(u16(data, base + 26))
        let extraLength = Int(u16(data, base + 28))
        let start = base + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw ZipError.malformed }
        let payload = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupported
        }
    }

    /// Raw-deflate decode via the Compression framework (zip's method 8).
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        // A zero-byte deflate payload (a malformed/truncated entry from the
        // file picker) would make `baseAddress` nil and crash the force-unwrap
        // below — reject it cleanly instead.
        guard !data.isEmpty else { throw ZipError.malformed }
        let capacity = max(expectedSize, 64)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw ZipError.malformed }
        return output.prefix(written)
    }

    // Bounds-safe: a malformed/truncated ZIP from the file picker must
    // never crash the importer — out-of-range reads return 0, which fails
    // the signature/offset guards cleanly.
    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < data.count else { return 0 }
        var value: UInt32 = 0
        for i in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return value
    }
}
