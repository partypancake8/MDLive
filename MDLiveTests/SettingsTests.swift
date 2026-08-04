import XCTest
@testable import MDLive

/// V1/V2 backbone tests: persistence (§3.1) + the JS opts mapping (§3.2) + derived
/// poll interval (DEC-V12). Saves/restores values so it doesn't corrupt real defaults.
final class SettingsTests: XCTestCase {

    func testPersistsToUserDefaults() {
        let s = Settings.shared
        let saved = s.fontScale
        s.fontScale = 1.7
        XCTAssertEqual(UserDefaults.standard.double(forKey: "mdlive.fontScale"), 1.7, accuracy: 0.001)
        s.fontScale = saved
    }

    func testJSOptsMapping() throws {
        let s = Settings.shared
        let (t, w, m) = (s.theme, s.contentWidth, s.mathEnabled)
        s.theme = "light"; s.contentWidth = "wide"; s.mathEnabled = true
        let obj = try JSONSerialization.jsonObject(
            with: Data(s.jsOptsJSON(customCSS: "body{color:red}").utf8)) as! [String: Any]
        XCTAssertEqual(obj["theme"] as? String, "light")
        XCTAssertEqual(obj["contentMax"] as? String, "1100px")
        XCTAssertEqual(obj["mathEnabled"] as? Bool, true)
        XCTAssertEqual(obj["customCSS"] as? String, "body{color:red}")
        s.theme = t; s.contentWidth = w; s.mathEnabled = m
    }

    func testPollIntervalMapping() {
        let s = Settings.shared
        let saved = s.pollSpeed
        s.pollSpeed = "fast";     XCTAssertEqual(s.pollInterval, 0.5, accuracy: 0.001)
        s.pollSpeed = "lowPower"; XCTAssertEqual(s.pollInterval, 3.0, accuracy: 0.001)
        s.pollSpeed = "normal";   XCTAssertEqual(s.pollInterval, 1.0, accuracy: 0.001)
        s.pollSpeed = saved
    }

    func testScrollMemoryRoundTrip() {
        let path = "/tmp/mdlive-scrolltest-\(UUID().uuidString).md"
        XCTAssertEqual(ScrollMemory.get(path), 0)           // unseen → 0
        ScrollMemory.save(path, 0.42)
        XCTAssertEqual(ScrollMemory.get(path), 0.42, accuracy: 0.001)
    }

    func testRestoreDefaults() {
        let s = Settings.shared
        s.theme = "light"; s.fontScale = 2.0; s.contentWidth = "full"; s.mathEnabled = true; s.autoRefresh = false
        s.restoreDefaults()
        XCTAssertEqual(s.theme, "dark")
        XCTAssertEqual(s.fontScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.contentWidth, "medium")
        XCTAssertFalse(s.mathEnabled)
        XCTAssertTrue(s.autoRefresh)
    }

    func testContentMaxMapping() {
        let s = Settings.shared
        let saved = s.contentWidth
        s.contentWidth = "narrow"; XCTAssertEqual(s.contentMaxCSS, "640px")
        s.contentWidth = "full";   XCTAssertEqual(s.contentMaxCSS, "100%")
        s.contentWidth = saved
    }
}
