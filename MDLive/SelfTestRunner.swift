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
                self?.readbackWhenSettled(r, outPath: outPath, attempts: 0)
            }
        }
        r.loadShell()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish("TIMEOUT", outPath: outPath, code: 2)
        }
    }

    /// Mermaid renders asynchronously after `render()`; poll (up to ~5 s) until the
    /// page reports it is no longer busy so the readback sees the final DOM.
    private func readbackWhenSettled(_ r: WebKitRenderer, outPath: String, attempts: Int) {
        r.webView.evaluateJavaScript("!!window.__mdliveMermaidBusy") { [weak self] v, _ in
            if (v as? Bool) == true && attempts < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.readbackWhenSettled(r, outPath: outPath, attempts: attempts + 1)
                }
                return
            }
            r.readback { json in
                self?.finish(json ?? "", outPath: outPath, code: json == nil ? 3 : 0)
            }
        }
    }

    private func finish(_ output: String, outPath: String, code: Int32) {
        if done { return }
        done = true
        try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
        exit(code)
    }
}

/// Headless edit gate. Env MDLIVE_EDIT_SELFTEST=<json out> + MDLIVE_OPEN=<file>,
/// optional MDLIVE_EDIT_TEXT=<text> and MDLIVE_EDIT_SELECTOR=<css, default "p">.
/// Opens the file offscreen through the real DocumentModel (editing on, autosave
/// on), puts the caret at the end of the first matching element, types the text
/// through the page's own editing path (execCommand insertText, so the same
/// input handler, block splice and autosave run), waits out the debounce, writes
/// a JSON readback and exits 0. With no text it only focuses and places the
/// caret, so the file must stay untouched (saveCount 0).
final class EditSelfTestRunner {
    static let shared = EditSelfTestRunner()
    private var model: DocumentModel?
    private var window: NSWindow?
    private var done = false
    private var target: Any = NSNull()

    func run(mdPath: String, outPath: String, text: String?, selector: String) {
        let url = URL(fileURLWithPath: mdPath).standardizedFileURL
        let m = DocumentModel(url: url)
        model = m
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = m.renderer.webView
        win.orderOut(nil)
        window = win

        m.renderer.onReady = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.edit(text: text, selector: selector, outPath: outPath) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { [weak self] in
            self?.finish(["error": "TIMEOUT"], outPath: outPath, code: 2)
        }
    }

    private func edit(text: String?, selector: String, outPath: String) {
        guard let m = model else { return }
        let js = "JSON.stringify(MDLiveEdit.selfTest(\(jsonString(selector)), \(text.map(jsonString) ?? "null")))"
        m.renderer.webView.evaluateJavaScript(js) { [weak self] v, err in
            guard let self else { return }
            if let s = v as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) { self.target = d }
            else { self.target = ["error": err.map { "\($0)" } ?? "no result"] }
            // Debounce plus settling time for the write and the watcher.
            let wait = (text?.isEmpty == false) ? m.saveDebounce + 1.2 : 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.readback(outPath: outPath) }
        }
    }

    private func readback(outPath: String) {
        guard let m = model else { return }
        m.renderer.webView.evaluateJavaScript("JSON.stringify(window.__mdliveEditInfo || {})") { [weak self] v, _ in
            var info: [String: Any] = [:]
            if let s = v as? String, let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] { info = d }
            let out: [String: Any] = [
                "savedPath": m.saveCount > 0 ? m.url.path : NSNull(),
                "saveCount": m.saveCount,
                "bytesWritten": m.bytesWritten,
                "changedBlocks": info["changedBlocks"] ?? 0,
                "posts": info["posts"] ?? 0,
                "blocks": info["blocks"] ?? 0,
                "target": self?.target ?? NSNull(),
            ]
            self?.finish(out, outPath: outPath, code: 0)
        }
    }

    private func finish(_ obj: [String: Any], outPath: String, code: Int32) {
        if done { return }
        done = true
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        }
        exit(code)
    }

    private func jsonString(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
