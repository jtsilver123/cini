import XCTest
@testable import Cini

/// Tests for the Letterboxd/IMDb import pipeline: native ZIP reading,
/// CSV edge cases, rating merge, and TMDB match scoring.
final class LetterboxdImporterTests: XCTestCase {

    /// A real Letterboxd-format export ZIP (deflate), generated from
    /// watched.csv + ratings.csv + watchlist.csv.
    static let fixtureZip = Data(base64Encoded: "UEsDBBQAAAAIAJWeylxUz7vgrQAAABMBAAAgAAAAbGV0dGVyYm94ZC1qYWtlLTIwMjYvd2F0Y2hlZC5jc3Z1zj0LwjAQgOHdXxE6X2yS+gHdhC6CH0Wr4pi2By3YpCQn+vNNxLGud/e8XKEJ4aAHhDtqBzskQlfbd8sup+1MCbXgIuNCQvE0mLNSO2LVy0LcQEc0+jxN4/28p1TXjYwmgDVXEo7jiKbDfkAXQTYF1A+suBSQnMe+Rcf32uRs0zjrPaMO2W98Recx+ZvKYkqFZ7lYQlIFd7POEysDs4b15tsKs0f7jcipyGL2AVBLAwQUAAAACACVnspcIeBzXYYAAADCAAAAIAAAAGxldHRlcmJveGQtamFrZS0yMDI2L3JhdGluZ3MuY3N2dc05DsIwEEDRPqfwAcbxEluI1GmQIogiKCgnMCIussgeluODJUqov55+g0ywx4ngTBihJWaKw/K6ilO/gx45zLfCauukrqQ20NxnqkWHkcXxuUAuMDKvqVYqszKwwuFiwGf1IRtpDRzWleaRwkQxk+oXseBK/115qbfQYWLRhgelv8aDK95QSwMEFAAAAAgAlZ7KXO5/CTdvAAAAjAAAACIAAABsZXR0ZXJib3hkLWpha2UtMjAyNi93YXRjaGxpc3QuY3N2c0ksSdXxS8xN1YlMTSzS8UktKUktSsqvSFEIDfLkMjIwMtE1MNM1MNQJyUhViMrPS1XIT1PwzAMqSi0u0QHKG+tklJQUFFvp64N06WWW6CcmJZtBdRqDdLqU5qVaKQQkFpUohJTng/SYYNNjyAUAUEsBAhQDFAAAAAgAlZ7KXFTPu+CtAAAAEwEAACAAAAAAAAAAAAAAAIABAAAAAGxldHRlcmJveGQtamFrZS0yMDI2L3dhdGNoZWQuY3N2UEsBAhQDFAAAAAgAlZ7KXCHgc12GAAAAwgAAACAAAAAAAAAAAAAAAIAB6wAAAGxldHRlcmJveGQtamFrZS0yMDI2L3JhdGluZ3MuY3N2UEsBAhQDFAAAAAgAlZ7KXO5/CTdvAAAAjAAAACIAAAAAAAAAAAAAAIABrwEAAGxldHRlcmJveGQtamFrZS0yMDI2L3dhdGNobGlzdC5jc3ZQSwUGAAAAAAMAAwDsAAAAXgIAAAAA")!

    // MARK: ZIP container

    func testZipListsAllEntries() throws {
        let entries = try ZipReader.entries(in: Self.fixtureZip)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.contains { $0.name.hasSuffix("watched.csv") })
        XCTAssertTrue(entries.contains { $0.name.hasSuffix("ratings.csv") })
        XCTAssertTrue(entries.contains { $0.name.hasSuffix("watchlist.csv") })
    }

    func testZipExtractsDeflatedCSV() throws {
        let entries = try ZipReader.entries(in: Self.fixtureZip)
        let watched = entries.first { $0.name.hasSuffix("watched.csv") }!
        let data = try ZipReader.extract(watched, from: Self.fixtureZip)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("Date,Name,Year"))
        XCTAssertTrue(text.contains("Oppenheimer"))
    }

    func testParseZipMergesRatingsAndWatchlist() throws {
        let titles = try LetterboxdImporter.parseZip(Self.fixtureZip)

        // 4 watched + 1 rated-but-not-watched + 1 new watchlist title.
        // Dune appears in watched AND watchlist -> watched wins after dedupe
        // happens in run(); parseZip itself keeps the raw merge.
        let dune = titles.first { $0.title == "Dune: Part Two" && !$0.isWatchlist }
        XCTAssertEqual(dune?.rating, 5.0)                  // merged from ratings.csv
        XCTAssertEqual(dune?.year, 2024)

        let oppenheimer = titles.first { $0.title == "Oppenheimer" }
        XCTAssertEqual(oppenheimer?.rating, 4.5)

        // Rated but missing from watched.csv still imports.
        XCTAssertTrue(titles.contains { $0.title == "Past Lives" && $0.rating == 4.0 })

        // Watchlist entries flagged correctly.
        XCTAssertTrue(titles.contains { $0.title == "The Zone of Interest" && $0.isWatchlist })
    }

    // MARK: CSV edge cases

    func testQuotedFieldsWithCommasAndEscapedQuotes() {
        let csv = """
        Date,Name,Year,Letterboxd URI
        2024-01-01,"I, Tonya",2017,uri
        2024-01-02,"The ""Best"" Movie",2020,uri
        """
        let titles = LetterboxdImporter.parse(csv: csv)
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles[0].title, "I, Tonya")
        XCTAssertEqual(titles[1].title, #"The "Best" Movie"#)
    }

    func testIMDbExportShape() {
        let csv = """
        Const,Your Rating,Date Rated,Title,URL,Title Type,IMDb Rating,Runtime (mins),Year,Genres
        tt1160419,9,2024-03-01,Dune: Part Two,url,Movie,8.5,166,2024,Sci-Fi
        tt0903747,10,2024-03-02,Breaking Bad,url,TV Series,9.5,49,2008,Crime
        """
        let titles = LetterboxdImporter.parse(csv: csv)
        XCTAssertEqual(titles.count, 1, "TV series rows must be filtered out")
        XCTAssertEqual(titles[0].title, "Dune: Part Two")
        XCTAssertEqual(titles[0].rating, 4.5, "IMDb 9/10 normalizes to 4.5 stars")
    }

    func testCRLFLineEndings() {
        let csv = "Date,Name,Year,Letterboxd URI\r\n2024-01-01,Heat,1995,uri\r\n"
        let titles = LetterboxdImporter.parse(csv: csv)
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles[0].title, "Heat")
        XCTAssertEqual(titles[0].year, 1995)
    }

    // MARK: Matching

    private func movie(_ id: Int, _ title: String, _ year: Int?) -> Movie {
        Movie(tmdbID: id, mediaKind: "movie", title: title, releaseYear: year,
              posterPath: nil, backdropPath: nil, genres: [], certification: nil,
              runtimeMinutes: nil, director: nil, overview: nil)
    }

    func testBestMatchPrefersExactTitleAndYear() {
        let imported = LetterboxdImporter.ImportedTitle(title: "Dune", year: 2021)
        let candidates = [
            movie(1, "Dune", 1984),
            movie(2, "Dune", 2021),
            movie(3, "Dune: Part Two", 2024),
        ]
        XCTAssertEqual(LetterboxdImporter.bestMatch(for: imported, in: candidates)?.tmdbID, 2)
    }

    func testBestMatchNormalizesPunctuationAndDiacritics() {
        let imported = LetterboxdImporter.ImportedTitle(title: "Amelie", year: 2001)
        let candidates = [movie(7, "Amélie", 2001)]
        XCTAssertEqual(LetterboxdImporter.bestMatch(for: imported, in: candidates)?.tmdbID, 7)
    }

    func testBestMatchRejectsWeakCandidates() {
        let imported = LetterboxdImporter.ImportedTitle(title: "Some Obscure Documentary", year: 1971)
        let candidates = [movie(9, "Completely Different Film", 2019)]
        XCTAssertNil(LetterboxdImporter.bestMatch(for: imported, in: candidates))
    }
}
