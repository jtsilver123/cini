import XCTest
import SwiftUI
@testable import Cini

/// Renders real SwiftUI views to PNG files so the actual UI can be eyeballed
/// without a device or a hand-built web mock. Each test composes a view, runs
/// it through `ImageRenderer` (the same renderer the share card uses), and
/// writes a PNG into a `snapshots/` folder at the repo root. CI uploads that
/// folder as a build artifact, so a render of the live SwiftUI is downloadable
/// after every push.
///
/// This is NOT a pass/fail comparison test — there are no reference images to
/// diff against. It exists purely to PRODUCE images. The assertions only guard
/// that rendering succeeded (non-empty PNG), so a view that fails to render
/// turns the build red instead of silently skipping.
@MainActor
final class SnapshotRenderTests: XCTestCase {

    /// Repo-root `snapshots/` directory, derived from this file's path so it
    /// works both locally and in CI (the iOS simulator can write to host paths,
    /// which is how snapshot-testing libraries persist references too).
    static let outputDir: URL = {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CiniTests/
            .deletingLastPathComponent()   // repo root
        return repoRoot.appendingPathComponent("snapshots", isDirectory: true)
    }()

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true)
    }

    /// Render `view` at `size` and write `<name>.png` into the snapshots dir.
    private func render<V: View>(_ name: String, size: CGSize, _ view: V) throws {
        let renderer = ImageRenderer(content:
            view
                .frame(width: size.width, height: size.height)
                .background(Theme.background)
        )
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            return XCTFail("ImageRenderer produced no image for \(name)")
        }
        XCTAssertGreaterThan(data.count, 0, "Empty PNG for \(name)")
        let url = Self.outputDir.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("snapshot: wrote \(url.path) (\(data.count) bytes)")
    }

    // MARK: - Proof of pipeline: design-system components

    func testComponentGallery() throws {
        let gallery = VStack(alignment: .leading, spacing: 20) {
            Text("Score badges")
                .font(.headline).foregroundStyle(Theme.ink)
            HStack(spacing: 16) {
                ScoreBadge(score: 9.2, count: 1200)
                ScoreBadge(score: 7.4)
                ScoreBadge(score: 4.1)
                ScoreChip(score: 8.4)
            }

            Text("Pill buttons")
                .font(.headline).foregroundStyle(Theme.ink)
            HStack(spacing: 12) {
                PillButton(title: "Watch", systemImage: "play.fill", style: .filled)
                PillButton(title: "Bookmark", systemImage: "bookmark", style: .outlined)
            }
        }
        .padding(24)

        try render("component-gallery", size: CGSize(width: 360, height: 320), gallery)
    }
}
