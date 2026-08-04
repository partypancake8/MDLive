import XCTest
@testable import MDLive

/// Link classification (DEC-11). Pure `classify` so routing is testable without
/// actually opening browsers/windows.
final class LinkRouterTests: XCTestCase {
    private let base = "/Users/x/docs"

    func testWeb() {
        XCTAssertEqual(LinkRouter.classify("https://example.com", baseDir: base), .web(URL(string: "https://example.com")!))
        XCTAssertEqual(LinkRouter.classify("mailto:a@b.com", baseDir: base), .web(URL(string: "mailto:a@b.com")!))
    }

    func testRelativeMarkdownResolvesUnderBase() {
        let r = LinkRouter.classify("notes/next.md", baseDir: base)
        XCTAssertEqual(r, .localMarkdown(URL(fileURLWithPath: "/Users/x/docs/notes/next.md")))
    }

    func testAbsoluteMarkdown() {
        XCTAssertEqual(LinkRouter.classify("/tmp/a.markdown", baseDir: base),
                       .localMarkdown(URL(fileURLWithPath: "/tmp/a.markdown")))
    }

    func testOtherLocalFile() {
        XCTAssertEqual(LinkRouter.classify("assets/pic.png", baseDir: base),
                       .localOther(URL(fileURLWithPath: "/Users/x/docs/assets/pic.png")))
    }
}
