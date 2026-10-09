import XCTest
@testable import MDLive

/// Version history store: recording, coalescing, caps, restore bytes, keys.
final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let file = URL(fileURLWithPath: "/tmp/mdlive-history-tests/notes.md")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mdlive-history-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func store() -> HistoryStore {
        let s = HistoryStore(root: root)
        s.now = { [unowned self] in self.clock }
        return s
    }

    func testHistoryRecordAndList() {
        let s = store()
        XCTAssertNotNil(s.record("one", for: file, label: .opened))
        clock += 10
        XCTAssertNotNil(s.record("two", for: file, label: .outside))
        let v = s.versions(for: file)
        XCTAssertEqual(v.map(\.label), ["opened", "outside"])
        XCTAssertEqual(v.map(\.bytes), [3, 3])
        XCTAssertEqual(s.snapshot(v[1].id, for: file), "two")
        let index = try? Data(contentsOf: s.folder(for: file).appendingPathComponent("index.json"))
        let json = index.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(json?["path"] as? String, file.path)
        let first = (json?["versions"] as? [[String: Any]])?.first
        XCTAssertNotNil((first?["timestamp"] as? String).flatMap { HistoryStore.iso.date(from: $0) })
        XCTAssertEqual(first?["sha256"] as? String, HistoryStore.sha256(Data("one".utf8)))
    }

    func testHistoryCoalescesYouWithinWindow() {
        let s = store()
        s.record("base", for: file, label: .opened)
        clock += 5; s.record("edit 1", for: file, label: .you)
        clock += 60; s.record("edit 2", for: file, label: .you)
        let v = s.versions(for: file)
        XCTAssertEqual(v.map(\.label), ["opened", "you"])
        XCTAssertEqual(v.last?.timestamp, clock)
        XCTAssertEqual(s.snapshot(v.last!.id, for: file), "edit 2")
    }

    func testHistoryDoesNotCoalesceOutsideWindowOrAcrossOutside() {
        let s = store()
        s.record("base", for: file, label: .opened)
        clock += 5; s.record("edit 1", for: file, label: .you)
        clock += 121; s.record("edit 2", for: file, label: .you)
        clock += 1; s.record("theirs", for: file, label: .outside)
        clock += 1; s.record("edit 3", for: file, label: .you)
        XCTAssertEqual(s.versions(for: file).map(\.label), ["opened", "you", "you", "outside", "you"])
    }

    func testHistorySkipsContentEqualToNewest() {
        let s = store()
        XCTAssertNotNil(s.record("same", for: file, label: .opened))
        clock += 500
        XCTAssertNil(s.record("same", for: file, label: .opened))
        XCTAssertNil(s.record("same", for: file, label: .outside))
        XCTAssertEqual(s.versions(for: file).count, 1)
    }

    func testHistoryPerFileCapDropsOldest() {
        let s = store()
        s.perFileCap = 5
        for i in 0..<8 { clock += 1; s.record("v\(i)", for: file, label: .outside) }
        let v = s.versions(for: file)
        XCTAssertEqual(v.count, 5)
        XCTAssertEqual(s.snapshot(v[0].id, for: file), "v3")
        let snaps = (try? FileManager.default.contentsOfDirectory(atPath: s.folder(for: file).path))?
            .filter { $0.hasSuffix(".md") } ?? []
        XCTAssertEqual(snaps.count, 5)
    }

    func testHistoryGlobalCapDropsOldestAcrossFiles() {
        let s = store()
        s.globalCapBytes = 100
        let other = URL(fileURLWithPath: "/tmp/mdlive-history-tests/other.md")
        let chunk = String(repeating: "a", count: 30)
        clock += 1; s.record(chunk + "1", for: file, label: .opened)      // oldest
        clock += 1; s.record(chunk + "2", for: other, label: .opened)
        clock += 1; s.record(chunk + "3", for: file, label: .outside)
        clock += 1; s.record(chunk + "4", for: other, label: .outside)    // 4 x 31 > 100
        let a = s.versions(for: file), b = s.versions(for: other)
        XCTAssertEqual(a.count + b.count, 3)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(s.snapshot(a[0].id, for: file), chunk + "3")
        XCTAssertLessThanOrEqual((a + b).reduce(0) { $0 + $1.bytes }, 100)
    }

    func testHistoryRestoreReturnsExactBytes() {
        let s = store()
        let text = "# Title\r\n\r\nCafé ✓ with CRLF\r\nno final newline"
        let v = s.record(text, for: file, label: .opened)!
        clock += 1; s.record("changed", for: file, label: .outside)
        XCTAssertEqual(s.snapshotData(v.id, for: file), Data(text.utf8))
    }

    func testHistoryPathHashIsStable() {
        let a = HistoryStore.key(for: URL(fileURLWithPath: "/tmp/x/../mdlive-history-tests/notes.md"))
        let b = HistoryStore.key(for: file)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, HistoryStore.sha256(Data(file.path.utf8)))
        XCTAssertEqual(b.count, 64)
        XCTAssertNotEqual(b, HistoryStore.key(for: URL(fileURLWithPath: "/tmp/other.md")))
    }

    func testHistoryDirOverrideHonored() {
        let dir = root.appendingPathComponent("override").path
        XCTAssertEqual(HistoryStore.defaultRoot(env: ["MDLIVE_HISTORY_DIR": dir]).path, dir)
        // Inside tests with no override, never the real Application Support folder.
        XCTAssertFalse(HistoryStore.defaultRoot(env: [:]).path.contains("Application Support"))
        XCTAssertFalse(HistoryStore.shared.root.path.contains("Application Support/MDLive/history"))
    }
}
