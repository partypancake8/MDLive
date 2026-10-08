import XCTest
@testable import MDLive

/// Native side of in-place editing: the autosave debounce and atomic write,
/// line-ending and final-newline preservation, and the watcher ignoring the
/// app's own writes. (The block splice itself runs in the page and is covered
/// by web-tests/edit-test.sh through the real WKWebView.)
final class EditingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdlive-edit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pump(_ seconds: TimeInterval) {
        let e = expectation(description: "pump")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 2)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>" }

    // MARK: line endings + final newline

    func testConformKeepsLFAndFinalNewline() {
        XCTAssertEqual(DocumentSaver.conform("a\nb", to: "a\nc\n"), "a\nb\n")
        XCTAssertEqual(DocumentSaver.conform("a\nb\n", to: "a\nc\n"), "a\nb\n")
    }

    func testConformKeepsMissingFinalNewline() {
        XCTAssertEqual(DocumentSaver.conform("a\nb\n", to: "a\nc"), "a\nb")
        XCTAssertEqual(DocumentSaver.conform("a\nb\n\n", to: "x"), "a\nb")
    }

    func testConformRestoresCRLF() {
        XCTAssertEqual(DocumentSaver.conform("# T\n\nnew para\n", to: "# T\r\n\r\nold\r\n"), "# T\r\n\r\nnew para\r\n")
        XCTAssertEqual(DocumentSaver.conform("a\r\nb", to: "a\r\nc"), "a\r\nb")
    }

    func testAtomicWriteKeepsPermissionsAndFollowsSymlink() throws {
        let real = dir.appendingPathComponent("real.md")
        try "old\n".write(to: real, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let n = try DocumentSaver.write("new text\n", to: link)

        XCTAssertEqual(n, 9)
        XCTAssertEqual(read(real), "new text\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink, "the symlink must survive the save")
        let perms = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    // MARK: autosave debounce

    func testAutosaveDebouncesToOneWriteOfTheLastText() throws {
        let file = dir.appendingPathComponent("a.md")
        try "# Title\r\n\r\nbody\r\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        model.saveDebounce = 0.3

        model.editDidChange("# Title\n\nbody x\n")
        model.editDidChange("# Title\n\nbody xy\n")
        model.editDidChange("# Title\n\nbody xyz\n")
        pump(0.15)
        XCTAssertEqual(model.saveCount, 0, "nothing is written inside the debounce window")
        XCTAssertEqual(read(file), "# Title\r\n\r\nbody\r\n")

        pump(0.6)
        XCTAssertEqual(model.saveCount, 1, "a burst of edits is one write")
        XCTAssertEqual(read(file), "# Title\r\n\r\nbody xyz\r\n", "last text wins, CRLF kept")
        XCTAssertEqual(model.bytesWritten, "# Title\r\n\r\nbody xyz\r\n".utf8.count)
    }

    func testEditThatRestoresTheFileWritesNothing() throws {
        let file = dir.appendingPathComponent("b.md")
        try "same\n".write(to: file, atomically: false, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let model = PreviewModel(url: file)
        model.saveDebounce = 0.1
        model.editDidChange("same")
        pump(0.4)
        XCTAssertEqual(model.saveCount, 0)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "an unchanged document must never be rewritten")
    }

    func testPendingEditWinsOverExternalChange() throws {
        let file = dir.appendingPathComponent("c.md")
        try "v0\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        model.saveDebounce = 1.0
        model.editDidChange("mine\n")
        try "theirs\n".write(to: file, atomically: false, encoding: .utf8)
        pump(1.6)
        XCTAssertEqual(read(file), "mine\n", "the pending save is the last writer")
        XCTAssertEqual(model.markdown, "mine\n")
    }

    func testFlushSaveWritesImmediately() throws {
        let file = dir.appendingPathComponent("d.md")
        try "v0\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        model.saveDebounce = 30
        model.editDidChange("v1\n")
        model.flushSave()
        XCTAssertEqual(read(file), "v1\n", "closing the window writes the pending edit")
        XCTAssertEqual(model.saveCount, 1)
    }

    // MARK: self-write suppression

    func testWatcherIgnoresNotedSelfWriteButSeesExternalOne() throws {
        let file = dir.appendingPathComponent("e.md")
        try "v0".write(to: file, atomically: false, encoding: .utf8)
        var changes = 0
        let watcher = FileWatcher(fileURL: file) { e in if case .changed = e { changes += 1 } }
        pump(0.3)

        try DocumentSaver.write("v1 by the app", to: file)
        watcher.noteSelfWrite()
        pump(1.5)
        XCTAssertEqual(changes, 0, "the app's own autosave must not come back as a change")

        try "v2 from another editor".write(to: file, atomically: false, encoding: .utf8)
        pump(1.5)
        XCTAssertGreaterThanOrEqual(changes, 1, "an outside write is still seen")
        watcher.stop()
    }

    func testModelDoesNotReRenderItsOwnSave() throws {
        let file = dir.appendingPathComponent("f.md")
        try "v0\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        model.saveDebounce = 0.1
        let firstLoad = model.lastUpdated
        model.editDidChange("v1\n")
        pump(1.8)
        XCTAssertEqual(model.saveCount, 1)
        XCTAssertEqual(model.lastUpdated, firstLoad, "no reload after the app's own write")
    }
}
