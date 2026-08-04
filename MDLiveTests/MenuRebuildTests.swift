import XCTest
import AppKit
@testable import MDLive

/// e2e for the Shortcuts → menu path: building the menu TWICE (a remap rebuilds it)
/// must not crash on a re-attached submenu, and the new key must reach the item.
/// This is the exact path that SIGABRT'd before the recentMenu fix.
final class MenuRebuildTests: XCTestCase {

    private func find(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let hit = find(sub, title) { return hit }
        }
        return nil
    }

    func testRebuildAfterRemapNoCrashAndAppliesKey() {
        let delegate = AppDelegate()
        Shortcuts.shared.reset("find")

        let menu1 = delegate.makeMainMenu()
        XCTAssertEqual(find(menu1, "Find…")?.keyEquivalent, "f")

        // Remap, then rebuild, before the fix this threw on `recentItem.setSubmenu:`.
        Shortcuts.shared.set("find", key: "j", mods: [.command, .shift])
        let menu2 = delegate.makeMainMenu()
        let find2 = find(menu2, "Find…")
        XCTAssertEqual(find2?.keyEquivalent, "j", "remapped key must reach the menu item")
        XCTAssertTrue(find2?.keyEquivalentModifierMask.contains(.shift) ?? false)

        // A third build proves repeated rebuilds are safe.
        _ = delegate.makeMainMenu()

        Shortcuts.shared.reset("find")
    }
}
