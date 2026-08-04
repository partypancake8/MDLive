import XCTest
@testable import MDLive

/// Step 6 watcher tests (PRD §6). Uses real temp files + FSEvents; assertions are
/// timing-tolerant but verify the contract: bursts coalesce, atomic replace is
/// seen, delete→recreate emits .deleted then .appeared.
final class FileWatcherTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdlive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ url: URL, _ s: String) throws {
        try s.write(to: url, atomically: false, encoding: .utf8)
    }

    func testBurstCoalescesToFewChanges() throws {
        let file = dir.appendingPathComponent("a.md")
        try write(file, "v0")

        var changes = 0
        let settled = expectation(description: "settled")
        var watcher: FileWatcher? = FileWatcher(fileURL: file) { event in
            if case .changed = event { changes += 1 }
        }

        // 10 rapid writes well within the 150ms debounce window.
        for i in 1...10 { try write(file, "v\(i) \(String(repeating: "x", count: i))") }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertGreaterThanOrEqual(changes, 1, "burst should yield at least one change")
        XCTAssertLessThanOrEqual(changes, 3, "burst should be debounced, not one-per-write")
        watcher = nil
        _ = watcher
    }

    func testAtomicReplaceIsSeen() throws {
        let file = dir.appendingPathComponent("b.md")
        try write(file, "original")

        let changed = expectation(description: "changed after atomic replace")
        changed.assertForOverFulfill = false
        var watcher: FileWatcher? = FileWatcher(fileURL: file) { event in
            if case .changed = event { changed.fulfill() }
        }

        // Write a temp sibling, then rename() over the target (how editors/agents save).
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let tmp = self.dir.appendingPathComponent("b.md.tmp")
            try? "replaced content, longer".write(to: tmp, atomically: false, encoding: .utf8)
            try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
        }

        wait(for: [changed], timeout: 4)
        watcher = nil
        _ = watcher
    }

    /// Step 10 teardown: releasing the model (what windowWillClose does) must
    /// deallocate it AND its FileWatcher — i.e. no retain cycle keeps a watcher
    /// alive after its window closes.
    func testModelAndWatcherDeallocate() throws {
        let file = dir.appendingPathComponent("d.md")
        try write(file, "x")

        weak var weakModel: PreviewModel?
        autoreleasepool {
            let model = PreviewModel(url: file)
            weakModel = model
            XCTAssertNotNil(weakModel)
        }

        let drained = expectation(description: "drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertNil(weakModel, "PreviewModel + FileWatcher must deallocate when released")
    }

    /// V3: a disabled watcher (auto-refresh off) emits nothing even after edits.
    func testDisabledWatcherEmitsNothing() throws {
        let file = dir.appendingPathComponent("e.md")
        try write(file, "v0")
        var changes = 0
        var watcher: FileWatcher? = FileWatcher(fileURL: file, enabled: false) { _ in changes += 1 }
        for i in 1...5 { try write(file, "v\(i) \(String(repeating: "y", count: i))") }
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { settled.fulfill() }
        wait(for: [settled], timeout: 4)
        XCTAssertEqual(changes, 0, "disabled watcher must not emit")
        watcher = nil
        _ = watcher
    }

    func testDeleteThenRecreate() throws {
        let file = dir.appendingPathComponent("c.md")
        try write(file, "here")

        let deleted = expectation(description: "deleted")
        let appeared = expectation(description: "appeared")
        deleted.assertForOverFulfill = false
        appeared.assertForOverFulfill = false

        var watcher: FileWatcher? = FileWatcher(fileURL: file) { event in
            switch event {
            case .deleted: deleted.fulfill()
            case .appeared: appeared.fulfill()
            case .changed: break
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                try? "back again".write(to: file, atomically: false, encoding: .utf8)
            }
        }

        wait(for: [deleted, appeared], timeout: 5, enforceOrder: true)
        watcher = nil
        _ = watcher
    }
}
