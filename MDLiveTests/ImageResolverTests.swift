import XCTest
@testable import MDLive

/// V4 / DEC-13: the mdlive-img path validator serves only files under the open
/// document's directory; traversal and outside-dir paths are rejected.
final class ImageResolverTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdlive-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("assets/a.png").path, contents: Data([0x89]))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func raw(_ absPath: String) -> String {
        "mdlive-img://" + (absPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? absPath)
    }

    func testUnderDirAllowed() {
        let p = dir.appendingPathComponent("assets/a.png").path
        XCTAssertNotNil(ImageSchemeHandler.resolve(rawURL: raw(p), docDir: dir.path))
    }

    func testTraversalRejected() {
        let escape = dir.appendingPathComponent("../../etc/hosts").path
        XCTAssertNil(ImageSchemeHandler.resolve(rawURL: raw(escape), docDir: dir.path))
    }

    func testAbsoluteOutsideRejected() {
        XCTAssertNil(ImageSchemeHandler.resolve(rawURL: raw("/etc/hosts"), docDir: dir.path))
    }

    func testNoDocDirRejected() {
        let p = dir.appendingPathComponent("assets/a.png").path
        XCTAssertNil(ImageSchemeHandler.resolve(rawURL: raw(p), docDir: nil))
    }
}
