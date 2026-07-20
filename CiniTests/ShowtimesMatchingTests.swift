import XCTest
@testable import Cini

/// Gracenote lists premium screenings as separate title variants — these
/// tests pin the canonicalization that lets "Dune: Part Two: The IMAX 2D
/// Experience" match the watchlist title "Dune: Part Two" (both in the
/// showtimes sheet and, mirrored in TypeScript, the nightly alert job).
final class ShowtimesMatchingTests: XCTestCase {

    func testVariantTitlesCanonicalize() {
        let cases: [(String, String)] = [
            ("Dune: Part Two: The IMAX 2D Experience", "Dune: Part Two"),
            ("Dune: Part Two – The IMAX Experience", "Dune: Part Two"),
            ("Oppenheimer 70mm", "Oppenheimer"),
            ("Oppenheimer in 70 mm", "Oppenheimer"),
            ("Casablanca (80th Anniversary)", "Casablanca"),
            ("Interstellar: An IMAX Experience", "Interstellar"),
            ("Avatar 3D", "Avatar"),
            ("Coraline (Re-Release)", "Coraline"),
            ("Aliens: Director's Cut", "Aliens"),
            ("Poor Things – Dolby Cinema", "Poor Things"),
            ("Spirited Away (2002)", "Spirited Away"),
            // Live-audit finds: real listings the patterns used to miss.
            ("Interstellar in 70mm Film", "Interstellar"),
            ("Blade Runner: The Final Cut", "Blade Runner"),
        ]
        for (raw, want) in cases {
            XCTAssertEqual(ShowtimesService.canonicalTitle(raw), want, raw)
        }
    }

    func testPlainTitlesPassThrough() {
        for title in ["The Final Cut", "Final Destination",
                      "Dune: Part Two", "Past Lives", "The Zone of Interest",
                      "M3GAN", "Se7en"] {
            XCTAssertEqual(ShowtimesService.canonicalTitle(title), title)
        }
    }

    func testFormatOnlyTitleIsNotEmptied() {
        // A title that IS a qualifier word must survive (never strip to "").
        XCTAssertFalse(ShowtimesService.canonicalTitle("IMAX").isEmpty)
    }

    func testTitlesEndingInFormatLikeTailsSurvive() {
        // Word boundaries: "Climax" ends in "imax" but is a real film — it
        // must never canonicalize to "Cl" (which would make it unmatchable).
        for title in ["Climax", "Anthropocene: The Human Epoch"] {
            XCTAssertEqual(ShowtimesService.canonicalTitle(title), title)
        }
    }

    func testTitleFallbackDetectsFormat() {
        XCTAssertEqual(GNShowingFormatProbe.format(in: "Dune: Part Two: The IMAX 2D Experience"), "IMAX")
        XCTAssertEqual(GNShowingFormatProbe.format(in: "Poor Things – Dolby Cinema"), "Dolby")
        XCTAssertNil(GNShowingFormatProbe.format(in: "Past Lives"))
        // Word boundary: "Climax" must NOT read as IMAX.
        XCTAssertNil(GNShowingFormatProbe.format(in: "Climax"))
        // Priority: IMAX outranks 3D no matter the qualifier order.
        XCTAssertEqual(GNShowingFormatProbe.format(in: "3D|IMAX"), "IMAX")
        // ATMOS is checked before Dolby, so "Dolby Atmos" reports the full
        // format (a plain "Dolby Cinema" still reports "Dolby" above).
        XCTAssertEqual(GNShowingFormatProbe.format(in: "Dolby Atmos"), "Dolby Atmos")
    }
}
