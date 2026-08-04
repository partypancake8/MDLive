import XCTest
import AppKit
@testable import MDLive

/// Shortcuts remap data layer (the key-recorder UI is verified manually).
final class ShortcutsTests: XCTestCase {

    func testDefaultRemapReset() {
        let s = Shortcuts.shared
        s.reset("find")
        XCTAssertEqual(s.key(for: "find"), "f")
        XCTAssertTrue(s.modifiers(for: "find").contains(.command))
        XCTAssertFalse(s.isCustom("find"))

        s.set("find", key: "j", mods: [.command, .shift])
        XCTAssertEqual(s.key(for: "find"), "j")
        XCTAssertTrue(s.isCustom("find"))
        XCTAssertTrue(s.modifiers(for: "find").contains(.shift))

        s.reset("find")
        XCTAssertEqual(s.key(for: "find"), "f")
        XCTAssertFalse(s.isCustom("find"))
    }

    func testResetAll() {
        let s = Shortcuts.shared
        s.set("find", key: "j", mods: [.command])
        s.set("refresh", key: "k", mods: [.command])
        s.resetAll()
        XCTAssertFalse(s.isCustom("find"))
        XCTAssertFalse(s.isCustom("refresh"))
        XCTAssertEqual(s.key(for: "find"), "f")
        XCTAssertEqual(s.key(for: "refresh"), "r")
    }

    func testDecodeFindResult() {
        XCTAssertEqual(WebKitRenderer.decodeFind("{\"count\":3,\"current\":2}").count, 3)
        XCTAssertEqual(WebKitRenderer.decodeFind("{\"count\":3,\"current\":2}").current, 2)
        XCTAssertEqual(WebKitRenderer.decodeFind("garbage").count, 0)
    }

    func testGlyphFormatting() {
        XCTAssertEqual(Shortcuts.glyphs(key: "j", mods: [.command, .shift]), "⇧⌘J")
        XCTAssertEqual(Shortcuts.glyphs(key: "1", mods: [.command, .option]), "⌥⌘1")
        XCTAssertEqual(Shortcuts.glyphs(key: "t", mods: [.command, .control]), "⌃⌘T")
    }
}
