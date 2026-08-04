import XCTest
import AppKit
@testable import MDLive

/// Recent-files data layer for the home-screen grid.
final class RecentFilesTests: XCTestCase {

    func testComputeListDedupeOrderCap() {
        var l = RecentFiles.computeList([], adding: "/a")
        XCTAssertEqual(l, ["/a"])
        l = RecentFiles.computeList(l, adding: "/b")
        XCTAssertEqual(l, ["/b", "/a"])            // most-recent first
        l = RecentFiles.computeList(l, adding: "/a")
        XCTAssertEqual(l, ["/a", "/b"])            // dedupe + move to front
        let many = (0..<15).map { "/f\($0)" }
        let capped = RecentFiles.computeList(many, adding: "/new", max: 10)
        XCTAssertEqual(capped.count, 10)
        XCTAssertEqual(capped.first, "/new")
    }

    func testExistingFiltersMissing() throws {
        let saved = UserDefaults.standard.array(forKey: "RecentFiles")
        defer { UserDefaults.standard.set(saved, forKey: "RecentFiles") }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appendingPathComponent("here.md")
        try "x".write(to: present, atomically: true, encoding: .utf8)
        let missing = dir.appendingPathComponent("gone.md")

        UserDefaults.standard.set([present.path, missing.path], forKey: "RecentFiles")
        let existing = RecentFiles.existing
        XCTAssertTrue(existing.contains(present))
        XCTAssertFalse(existing.contains(missing))
    }

    func testPreviewSnippetBounds() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let f = dir.appendingPathComponent("prev-\(UUID().uuidString).md")
        let body = (1...40).map { "line \($0)" }.joined(separator: "\n")
        try body.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }

        let snip = FilePreview.snippet(for: f, maxLines: 14, maxChars: 600)
        XCTAssertTrue(snip.hasPrefix("line 1"))
        XCTAssertFalse(snip.contains("line 15"))                       // capped at 14 lines
        XCTAssertLessThanOrEqual(snip.components(separatedBy: "\n").count, 14)
    }

    func testPreviewMissingFileIsEmpty() {
        XCTAssertEqual(FilePreview.snippet(for: URL(fileURLWithPath: "/nope/zzz.md")), "")
    }
}
