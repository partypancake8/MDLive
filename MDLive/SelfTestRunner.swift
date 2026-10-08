import Foundation
import AppKit
import WebKit
import SwiftUI

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

/// Headless editor gate. Launched via env MDLIVE_OPEN + MDLIVE_EDIT_SELFTEST +
/// MDLIVE_EDIT_TEXT: opens the file in a real DocumentView inside an offscreen
/// window, replaces the editor text through NSTextView.insertText (the same path
/// a keystroke takes), waits for the real autosave debounce to write the file,
/// checks the preview re-rendered, writes a JSON readback, and exits.
final class EditSelfTestRunner {
    static let shared = EditSelfTestRunner()
    private var model: PreviewModel?
    private var window: NSWindow?
    private var done = false
    private var saved: (path: String, bytes: Int)?

    func run(mdPath: String, text: String, outPath: String) {
        let url = URL(fileURLWithPath: mdPath)
        let m = PreviewModel(url: url)
        m.autosaveOverride = true            // the gate exercises autosave even if the user turned it off
        m.setViewMode(.split, persist: false)
        model = m

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentViewController = NSHostingController(rootView: DocumentView(model: m))
        win.orderOut(nil)
        win.contentView?.layoutSubtreeIfNeeded()
        window = win

        m.onSaved = { [weak self] path, bytes in
            guard let self, self.saved == nil else { return }
            self.saved = (path, bytes)
            self.checkRender(text: text, outPath: outPath, attempts: 0)
        }

        // Give the web shell a moment to load, then "type".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = m.editorScrollView()
            guard let tv = m.textView else { self.finish(["error": "no text view"], outPath: outPath, code: 4); return }
            let all = NSRange(location: 0, length: (tv.string as NSString).length)
            tv.setSelectedRange(all)
            tv.insertText(text, replacementRange: all)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { [weak self] in
            self?.finish(["error": "TIMEOUT", "saved": self?.saved != nil], outPath: outPath, code: 2)
        }
    }

    /// Poll the rendered DOM until it shows the new text (render debounce ~150 ms).
    private func checkRender(text: String, outPath: String, attempts: Int) {
        guard let m = model, let saved else { return }
        let needle = text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "#>-* ")) } ?? ""
        m.renderer.webView.evaluateJavaScript("(document.getElementById('content')||{}).innerText||''") { [weak self] v, _ in
            let rendered = (v as? String) ?? ""
            let ok = needle.isEmpty || rendered.contains(needle)
            if !ok && attempts < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.checkRender(text: text, outPath: outPath, attempts: attempts + 1)
                }
                return
            }
            let onDisk = (try? String(contentsOfFile: saved.path, encoding: .utf8)) ?? ""
            self?.finish(["savedPath": saved.path, "bytesWritten": saved.bytes, "renderOK": ok,
                          "saveCount": m.saveCount, "dirtyAfter": m.isDirty,
                          "diskMatches": onDisk == DiskText.encode(text, lineEnding: m.lineEnding, trailingNewline: m.trailingNewline)],
                         outPath: outPath, code: ok ? 0 : 3)
        }
    }

    private func finish(_ obj: [String: Any], outPath: String, code: Int32) {
        if done { return }
        done = true
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        try? data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        exit(code)
    }
}
