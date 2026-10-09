import XCTest
import AppKit
@testable import MDLive

/// The Edit and Format menus, and the Link… prompt's clipboard prefill.
final class FormatMenuTests: XCTestCase {

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu? {
        main.items.compactMap { $0.submenu }.first { $0.title == title }
    }

    func testLinkCandidateFromClipboard() {
        XCTAssertEqual(AppDelegate.linkCandidate("https://example.com/a?b=1"), "https://example.com/a?b=1")
        XCTAssertEqual(AppDelegate.linkCandidate("  http://x.org\n"), "http://x.org")
        XCTAssertEqual(AppDelegate.linkCandidate("mailto:me@example.com"), "mailto:me@example.com")
        XCTAssertNil(AppDelegate.linkCandidate(nil))
        XCTAssertNil(AppDelegate.linkCandidate(""))
        XCTAssertNil(AppDelegate.linkCandidate("just some words"))
        XCTAssertNil(AppDelegate.linkCandidate("example.com"))
        XCTAssertNil(AppDelegate.linkCandidate("https://"))
        XCTAssertNil(AppDelegate.linkCandidate("file:///etc/hosts"))
    }

    func testEditMenuIsStandard() {
        let main = AppDelegate().makeMainMenu()
        let edit = submenu(main, "Edit")
        let titles = edit?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        XCTAssertEqual(Array(titles.prefix(6)), ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"])
        let paste = edit?.items.first { $0.title == "Paste" }
        XCTAssertEqual(paste?.keyEquivalent, "v")
        XCTAssertNil(paste?.target, "nil target so the responder chain reaches the WebView")
        let redo = edit?.items.first { $0.title == "Redo" }
        XCTAssertTrue(redo?.keyEquivalentModifierMask.contains(.shift) ?? false)
    }

    func testFormatMenuReadsShortcutStore() {
        Shortcuts.shared.reset("bold")
        let delegate = AppDelegate()
        let format = submenu(delegate.makeMainMenu(), "Format")
        XCTAssertNotNil(format)
        let titles = format?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        XCTAssertEqual(titles, ["Bold", "Italic", "Strikethrough", "Code", "Heading 1", "Heading 2", "Heading 3",
                                "Body Text", "Bulleted List", "Numbered List", "Link…"])
        XCTAssertEqual(format?.items.first { $0.title == "Bold" }?.keyEquivalent, "b")
        XCTAssertEqual(format?.items.first { $0.title == "Heading 2" }?.keyEquivalentModifierMask, [.command, .control])

        Shortcuts.shared.set("bold", key: "j", mods: [.command, .option])
        let remapped = submenu(delegate.makeMainMenu(), "Format")?.items.first { $0.title == "Bold" }
        XCTAssertEqual(remapped?.keyEquivalent, "j")
        Shortcuts.shared.reset("bold")
    }
}
