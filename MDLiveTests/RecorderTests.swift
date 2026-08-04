import XCTest
import AppKit
@testable import MDLive

/// The key-recorder capture path (what crashed/was untested before). Synthetic
/// NSEvents exercise performKeyEquivalent/keyDown without a real GUI keypress.
final class RecorderTests: XCTestCase {

    private func keyEvent(_ chars: String, _ mods: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    func testCapturesModifierCombo() {
        let v = KeyRecorder.RecorderNSView()
        var captured: (String, NSEvent.ModifierFlags)?
        v.onCapture = { captured = ($0, $1) }
        let handled = v.performKeyEquivalent(with: keyEvent("F", [.command, .shift]))
        XCTAssertTrue(handled)
        XCTAssertEqual(captured?.0, "f")
        XCTAssertTrue(captured?.1.contains(.command) ?? false)
        XCTAssertTrue(captured?.1.contains(.shift) ?? false)
    }

    func testIgnoresBareKey() {
        let v = KeyRecorder.RecorderNSView()
        var called = false
        v.onCapture = { _, _ in called = true }
        XCTAssertFalse(v.performKeyEquivalent(with: keyEvent("a", [])))
        XCTAssertFalse(called)
    }

    func testEscCancels() {
        let v = KeyRecorder.RecorderNSView()
        var cancelled = false
        v.onCancel = { cancelled = true }
        v.keyDown(with: keyEvent("\u{1b}", [], keyCode: 53))
        XCTAssertTrue(cancelled)
    }

    /// Full remap chain: capture → Shortcuts.set → the rebuilt menu carries the new key.
    func testCaptureToMenuChain() {
        Shortcuts.shared.reset("find")
        let v = KeyRecorder.RecorderNSView()
        v.onCapture = { Shortcuts.shared.set("find", key: $0, mods: $1) }
        _ = v.performKeyEquivalent(with: keyEvent("J", [.command, .shift]))
        XCTAssertEqual(Shortcuts.shared.key(for: "find"), "j")

        let menu = AppDelegate().makeMainMenu()
        XCTAssertEqual(Self.find(menu, "Find…")?.keyEquivalent, "j")
        Shortcuts.shared.reset("find")
    }

    static func find(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        for i in menu.items {
            if i.title == title { return i }
            if let s = i.submenu, let h = find(s, title) { return h }
        }
        return nil
    }
}
