import XCTest
import AppKit
@testable import MDLive

/// Editing + autosave: debounce and atomic write, self-write suppression in the
/// watcher, the external-change-while-dirty conflict path, Save As re-keying in
/// WindowManager, and the defaults for the new settings keys. Everything runs on
/// temp files and offscreen windows; nothing is put on screen.
final class AutosaveTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdlive-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func inode(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
    private func spin(_ seconds: TimeInterval) {
        let e = expectation(description: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 2)
    }

    // MARK: disk encoding

    func testDiskTextKeepsLineEndingsAndTrailingNewline() {
        let crlf = DiskText.detect("a\r\nb\r\n")
        XCTAssertEqual(crlf.lineEnding, "\r\n")
        XCTAssertTrue(crlf.trailingNewline)
        XCTAssertEqual(DiskText.normalize("a\r\nb\r\n"), "a\nb\n")
        XCTAssertEqual(DiskText.encode("x\ny", lineEnding: "\r\n", trailingNewline: true), "x\r\ny\r\n")

        let bare = DiskText.detect("no newline")
        XCTAssertEqual(bare.lineEnding, "\n")
        XCTAssertFalse(bare.trailingNewline)
        XCTAssertEqual(DiskText.encode("still none", lineEnding: "\n", trailingNewline: false), "still none")
    }

    // MARK: autosave debounce + atomic write

    func testAutosaveDebouncesAndWritesAtomically() throws {
        let file = dir.appendingPathComponent("a.md")
        try "# start\n".write(to: file, atomically: false, encoding: .utf8)
        let before = inode(file)

        let model = PreviewModel(url: file)
        model.autosaveOverride = true
        model.autosaveDelay = 0.4

        // A burst of keystrokes inside the debounce window.
        model.userEdited("# s")
        model.userEdited("# sa")
        model.userEdited("# saved")
        XCTAssertTrue(model.isDirty)

        spin(0.15)
        XCTAssertEqual(read(file), "# start\n", "nothing is written before the debounce fires")
        XCTAssertEqual(model.saveCount, 0)

        spin(0.8)
        XCTAssertEqual(read(file), "# saved\n", "trailing newline from the original file is kept")
        XCTAssertEqual(model.saveCount, 1, "the burst coalesces into one write")
        XCTAssertFalse(model.isDirty)
        XCTAssertNotEqual(inode(file), before, "atomic write replaces the file via rename")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".tmp"))
    }

    func testAutosaveOffWaitsForExplicitSave() throws {
        let file = dir.appendingPathComponent("off.md")
        try "a\r\nb\r\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        model.autosaveOverride = false
        model.autosaveDelay = 0.2
        XCTAssertEqual(model.editorText, "a\nb\n", "editor works in plain newlines")
        model.userEdited("a\nb\nc")
        spin(0.6)
        XCTAssertEqual(read(file), "a\r\nb\r\n", "autosave off never writes on its own")
        XCTAssertTrue(model.isDirty)
        try model.save()
        XCTAssertEqual(read(file), "a\r\nb\r\nc\r\n", "CRLF and trailing newline are restored on save")
        XCTAssertFalse(model.isDirty)
    }

    // MARK: watcher self-write suppression

    func testSelfWriteDoesNotEmitChange() throws {
        let file = dir.appendingPathComponent("self.md")
        try "v0".write(to: file, atomically: false, encoding: .utf8)
        var changes = 0
        var watcher: FileWatcher? = FileWatcher(fileURL: file, pollInterval: 0.3) { e in
            if case .changed = e { changes += 1 }
        }
        try watcher!.performSelfWrite {
            try Data("v1 written by the app itself".utf8).write(to: file, options: .atomic)
        }
        spin(1.2)
        XCTAssertEqual(changes, 0, "an app-originated write must not come back as a change")

        // A real external write right after is still seen.
        try "v2 from somebody else, longer".write(to: file, atomically: false, encoding: .utf8)
        spin(1.2)
        XCTAssertGreaterThanOrEqual(changes, 1, "external writes still emit")
        watcher = nil
        _ = watcher
    }

    func testModelAutosaveDoesNotReloadOrConflict() throws {
        let file = dir.appendingPathComponent("loop.md")
        try "one\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        model.autosaveOverride = true
        model.autosaveDelay = 0.2
        model.userEdited("two")
        spin(0.5)
        XCTAssertEqual(read(file), "two\n")
        // Typing continues after the save; a late watcher event must not clobber it.
        model.userEdited("two and three")
        model.handle(.changed)
        XCTAssertEqual(model.editorText, "two and three")
        XCTAssertFalse(model.conflict)
    }

    // MARK: external change with a dirty buffer

    func testExternalChangeWithDirtyBufferShowsConflict() throws {
        let file = dir.appendingPathComponent("conflict.md")
        try "base\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        model.autosaveOverride = false
        model.userEdited("mine")

        try "theirs\n".write(to: file, atomically: false, encoding: .utf8)
        model.handle(.changed)
        XCTAssertTrue(model.conflict, "a dirty buffer plus an outside change raises the bar")
        XCTAssertEqual(model.editorText, "mine", "the buffer is never clobbered")
        XCTAssertEqual(read(file), "theirs\n", "and neither is the file")

        model.keepMine()
        XCTAssertFalse(model.conflict)
        try model.save()
        XCTAssertEqual(read(file), "mine\n")

        // Reload path: take the disk version.
        model.userEdited("mine again")
        try "outside again\n".write(to: file, atomically: false, encoding: .utf8)
        model.handle(.changed)
        XCTAssertTrue(model.conflict)
        model.reloadFromDisk()
        XCTAssertFalse(model.conflict)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.editorText, "outside again\n")
    }

    func testExternalChangeWithCleanBufferReplacesText() throws {
        let file = dir.appendingPathComponent("clean.md")
        try "first\n".write(to: file, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: file)
        try "second\n".write(to: file, atomically: false, encoding: .utf8)
        model.handle(.changed)
        XCTAssertFalse(model.conflict)
        XCTAssertEqual(model.editorText, "second\n")
        XCTAssertEqual(model.markdown, "second\n")
    }

    // MARK: Save As re-keying

    func testSaveAsRekeysWindowManager() throws {
        let a = dir.appendingPathComponent("a.md")
        let b = dir.appendingPathComponent("b.md")
        try "# a\n".write(to: a, atomically: false, encoding: .utf8)
        let model = PreviewModel(url: a)
        model.autosaveOverride = false
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        WindowManager.shared.register(model, window: win)
        defer { WindowManager.shared.unregister(window: win) }
        XCTAssertTrue(WindowManager.shared.window(for: a) === win)

        model.userEdited("# b")
        try model.saveAs(to: b)
        XCTAssertEqual(model.url, b.standardizedFileURL)
        XCTAssertEqual(read(b), "# b\n")
        XCTAssertEqual(read(a), "# a\n", "Save As leaves the original alone")
        XCTAssertNil(WindowManager.shared.window(for: a), "the old key is gone")
        XCTAssertTrue(WindowManager.shared.window(for: b) === win, "dedupe follows the new path")
        XCTAssertEqual(win.title, "b.md")
    }

    func testUntitledFirstSaveRekeys() throws {
        let c = dir.appendingPathComponent("new.md")
        let model = PreviewModel(url: nil)
        XCTAssertNil(model.url)
        XCTAssertEqual(model.viewMode, .split, "a new buffer opens with the editor showing")
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        WindowManager.shared.register(model, window: win)
        defer { WindowManager.shared.unregister(window: win) }
        model.userEdited("# fresh")
        try model.saveAs(to: c)
        XCTAssertEqual(read(c), "# fresh\n")
        XCTAssertTrue(WindowManager.shared.window(for: c) === win)
    }

    // MARK: settings defaults

    func testEditingSettingsDefaults() {
        let s = Settings.shared
        let (a, m) = (s.autosave, s.viewMode)
        defer { s.autosave = a; s.viewMode = m }
        XCTAssertTrue(Settings.defaultAutosave)
        XCTAssertEqual(Settings.defaultViewMode, "preview")
        s.autosave = false; s.viewMode = "split"
        XCTAssertEqual(UserDefaults.standard.object(forKey: "mdlive.autosave") as? Bool, false)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "mdlive.viewMode"), "split")
        s.restoreDefaults()
        XCTAssertTrue(s.autosave)
        XCTAssertEqual(s.viewMode, "preview")
        XCTAssertEqual(ViewMode(rawValue: s.viewMode), .preview)
    }

    func testViewModeShortcutsAreRegistered() {
        for id in ["modePreview", "modeSplit", "modeEditor", "newDocument", "save", "saveAs"] {
            XCTAssertTrue(Shortcuts.shared.commands.contains { $0.id == id }, "\(id) missing from Shortcuts")
        }
        XCTAssertEqual(Shortcuts.shared.commands.first { $0.id == "save" }?.defaultKey, "s")
    }
}
