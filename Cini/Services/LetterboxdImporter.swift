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
    }

    struct MatchedTitle: Identifiable, Hashable {
        let imported: ImportedTitle
        let movie: Movie
        var id: Int { movie.tmdbID }
    }

    struct Result {
        var watched: [MatchedTitle] = []
        var watchlist: [MatchedTitle] = []
        var unmatched: [ImportedTitle] = []
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
        guard fileURL.startAccessingSecurityScopedResource() else { throw ImportError.unreadableFile }
        defer { fileURL.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: fileURL) else { throw ImportError.unreadableFile }

        var titles: [ImportedTitle]
        if fileURL.pathExtension.lowercased() == "zip" || data.starts(with: [0x50, 0x4B]) {
            titles = try parseZip(data)
        } else {
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { throw ImportError.unreadableFile }
            titles = parse(csv: text, assumeWatchlist: fileURL.lastPathComponent.lowercased().contains("watchlist"))
            if titles.isEmpty {
                // Not a CSV export — treat it as a plain list of titles
                // (an Apple Notes export, a .txt, whatever).
                titles = parseFreeText(text)
            }
        }

        titles = dedupe(titles)
        guard !titles.isEmpty else { throw ImportError.noTitlesFound }

        return try await match(titles: titles, tmdb: tmdb, onProgress: onProgress)
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

    static func parseZip(_ data: Data) throws -> [ImportedTitle] {
        let entries = try ZipReader.entries(in: data)
        var titles: [ImportedTitle] = []
        // Prefer watched.csv (full history); diary.csv only adds dates.
        let wanted = ["watched.csv", "ratings.csv", "watchlist.csv"]
        for name in wanted {
            guard let entry = entries.first(where: { $0.name.lowercased().hasSuffix(name) }),
                  let bytes = try? ZipReader.extract(entry, from: data),
                  let text = String(data: bytes, encoding: .utf8) else { continue }
            let parsed = parse(csv: text, assumeWatchlist: name == "watchlist.csv")
            if name == "ratings.csv" {
                // Merge ratings into already-seen watched titles.
                var ratingByKey: [String: Double] = [:]
                for entry in parsed { ratingByKey[key(entry)] = entry.rating }
                titles = titles.map { title in
                    var copy = title
                    if copy.rating == nil { copy.rating = ratingByKey[key(title)] }
                    return copy
                }
                // Plus any rated film missing from watched.csv.
                let known = Set(titles.map(key))
                titles += parsed.filter { !known.contains(key($0)) }
            } else {
                titles += parsed
            }
        }
        return titles
    }

    private static func key(_ title: ImportedTitle) -> String {
        normalize(title.title) + "|" + (title.year.map(String.init) ?? "")
    }

    static func dedupe(_ titles: [ImportedTitle]) -> [ImportedTitle] {
        var seen = Set<String>()
        var result: [ImportedTitle] = []
        // Watched entries win over watchlist duplicates.
        for title in titles.sorted(by: { !$0.isWatchlist && $1.isWatchlist }) {
            if seen.insert(key(title)).inserted {
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
        let ratingIndex = columns.firstIndex { $0 == "rating" || $0 == "your rating" }
        let typeIndex = columns.firstIndex { $0 == "title type" }
        let isIMDb = columns.contains("const")

        return rows.dropFirst().compactMap { fields in
            guard fields.indices.contains(titleIndex) else { return nil }
            let title = fields[titleIndex].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            // IMDb exports mix in TV; keep only movie-ish rows.
            if let typeIndex, fields.indices.contains(typeIndex) {
                let type = fields[typeIndex].lowercased()
                guard type.isEmpty || type.contains("movie") else { return nil }
            }
            let year = yearIndex.flatMap { fields.indices.contains($0) ? Int(fields[$0].prefix(4)) : nil }
            var rating = ratingIndex.flatMap { fields.indices.contains($0) ? Double(fields[$0]) : nil }
            if isIMDb, let r = rating { rating = r / 2 }   // 1–10 → 0.5–5
            return ImportedTitle(title: title, year: year, rating: rating, isWatchlist: assumeWatchlist)
        }
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

        // Bounded concurrency: gentle on TMDB, fast for 1000+ film libraries.
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

            for _ in 0..<5 { addNext() }
            while inFlight > 0 {
                guard let (imported, movie) = try await group.next() else { break }
                inFlight -= 1
                done += 1
                if let movie {
                    let matched = MatchedTitle(imported: imported, movie: movie)
                    if imported.isWatchlist { result.watchlist.append(matched) }
                    else { result.watched.append(matched) }
                } else {
                    result.unmatched.append(imported)
                }
                await onProgress(.matching(done: done, total: total))
                addNext()
            }
        }

        // Favorites first: queue ordered by their old rating, then recency.
        result.watched.sort {
            ($0.imported.rating ?? -1, $0.movie.releaseYear ?? 0)
                > ($1.imported.rating ?? -1, $1.movie.releaseYear ?? 0)
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

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return value
    }
}
