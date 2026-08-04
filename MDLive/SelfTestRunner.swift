import Foundation
import AppKit
import WebKit

/// Headless render gate (PRD §6). Launched via env MDLIVE_OPEN + MDLIVE_SELFTEST:
/// opens the md offscreen, renders it, reads the rendered DOM back, writes it to
/// the output path, and exits. Proves real rendering without a human looking.
final class SelfTestRunner {
    static let shared = SelfTestRunner()
    private var renderer: WebKitRenderer?
    private var window: NSWindow?
    private var done = false

    func run(mdPath: String, outPath: String) {
        let url = URL(fileURLWithPath: mdPath)
        let md = (try? String(contentsOf: url, encoding: .utf8)) ?? "# (unreadable)"
        let baseDir = url.deletingLastPathComponent().path

        let r = WebKitRenderer()
        renderer = r

        // Offscreen host window so the WebView lays out and runs JS.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = r.webView
        win.orderOut(nil)
        window = win

        r.onReady = { [weak self] in
            r.render(markdown: md, baseDir: baseDir, scrollPct: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                r.readback { json in
                    self?.finish(json ?? "", outPath: outPath, code: json == nil ? 3 : 0)
                }
            }
        }
        r.loadShell()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish("TIMEOUT", outPath: outPath, code: 2)
        }
    }

    private func finish(_ output: String, outPath: String, code: Int32) {
        if done { return }
        done = true
        try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
        exit(code)
    }
}
