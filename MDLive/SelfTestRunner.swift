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
///
/// Formatting and clipboard:
/// - MDLIVE_EDIT_SELECT_WORD=<text>: select the first occurrence of the text.
/// - MDLIVE_EDIT_FORMAT=<cmd>[,<cmd>...]: run Format menu commands through
///   DocumentModel.format, the same path the Format menu uses.
/// - MDLIVE_EDIT_PASTE_HTML=<html>: caret at the end of the first <p>, then a
///   paste event carrying that HTML goes through the page's real paste handler.
/// - MDLIVE_EDIT_UNDO=1: type a probe token, run the Edit menu's Undo item
///   through the responder chain, and report whether the token is gone.
final class EditSelfTestRunner {
    static let shared = EditSelfTestRunner()
    private var model: DocumentModel?
    private var window: NSWindow?
    private var done = false
    private var target: Any = NSNull()
    private var formatResult: Any = NSNull()
    private var undoWorked: Any = NSNull()

    struct Plan {
        var text: String?
        var selector: String
        var selectWord: String?
        var formats: [String]
        var pasteHTML: String?
        var undo: Bool
        var changes: Bool { text?.isEmpty == false || !formats.isEmpty || pasteHTML != nil || undo }
    }

    func run(mdPath: String, outPath: String, text: String?, selector: String,
             selectWord: String? = nil, format: String? = nil, pasteHTML: String? = nil, undo: Bool = false) {
        let formats = (format ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let plan = Plan(text: text, selector: selector, selectWord: selectWord,
                        formats: formats, pasteHTML: pasteHTML, undo: undo)
        let url = URL(fileURLWithPath: mdPath).standardizedFileURL
        let m = DocumentModel(url: url)
        model = m
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = m.renderer.webView
        win.orderOut(nil)
        win.makeFirstResponder(m.renderer.webView)
        window = win

        m.renderer.onReady = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.edit(plan, outPath: outPath) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { [weak self] in
            self?.finish(["error": "TIMEOUT"], outPath: outPath, code: 2)
        }
    }

    /// Evaluate `js` in the page and hand back its JSON-decoded value.
    private func eval(_ js: String, _ done: @escaping (Any?) -> Void) {
        model?.renderer.webView.evaluateJavaScript("JSON.stringify(\(js))") { v, err in
            if let s = v as? String,
               let d = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) { done(d) }
            else { done(["error": err.map { "\($0)" } ?? "no result"]) }
        }
    }

    private func edit(_ plan: Plan, outPath: String) {
        guard let m = model else { return }
        let afterEdit = { [weak self] in
            guard let self else { return }
            let next = { [weak self] in
                // Debounce plus settling time for the write and the watcher.
                let wait = plan.changes ? m.saveDebounce + 1.2 : 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self?.readback(outPath: outPath) }
            }
            if plan.undo { self.probeUndo(selector: plan.selector, then: next) } else { next() }
        }
        if let html = plan.pasteHTML {
            let paste = "MDLiveEdit.testPaste(\(jsonString(html)))"
            eval("MDLiveEdit.selfTest(\"p\", null)") { [weak self] t in
                self?.target = t ?? NSNull()
                self?.eval(paste) { r in self?.formatResult = r ?? NSNull(); afterEdit() }
            }
            return
        }
        let typed = plan.formats.isEmpty ? (plan.text.map(jsonString) ?? "null") : "null"
        let place = plan.selectWord.map { "MDLiveEdit.selectText(\(jsonString($0)))" }
            ?? "MDLiveEdit.selfTest(\(jsonString(plan.selector)), \(typed))"
        eval(place) { [weak self] t in
            guard let self else { return }
            self.target = t ?? NSNull()
            self.runFormats(plan.formats, results: []) { results in
                if !plan.formats.isEmpty { self.formatResult = ["commands": plan.formats, "ok": results] }
                afterEdit()
            }
        }
    }

    /// Run each Format command in order through DocumentModel.format.
    private func runFormats(_ cmds: [String], results: [Bool], done: @escaping ([Bool]) -> Void) {
        guard let m = model, let first = cmds.first else { done(results); return }
        m.format(first) { [weak self] ok in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.runFormats(Array(cmds.dropFirst()), results: results + [ok], done: done)
            }
        }
    }

    /// Type a token, then send the Edit menu's own Undo item action up the
    /// responder chain from the WebView, as the menu does with a nil target.
    private func probeUndo(selector: String, then next: @escaping () -> Void) {
        guard let m = model else { return }
        let token = "undo-probe-token"
        let gone = "document.getElementById('content').textContent.indexOf(\(jsonString(token))) < 0"
        eval("MDLiveEdit.selfTest(\(jsonString(selector)), \(jsonString(token)))") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // The same menu the app installs (NSApp.delegate is SwiftUI's adaptor, so build one).
                let menu: NSMenu? = AppDelegate().makeMainMenu()
                let edit = menu?.items.compactMap { $0.submenu }.first { $0.title == "Edit" }
                let undoItem = edit?.items.first { $0.title == "Undo" }
                let sent = undoItem?.action.map { m.renderer.webView.tryToPerform($0, with: undoItem) } ?? false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.eval(gone) { g in
                        self?.undoWorked = sent && ((g as? Bool) ?? false)
                        next()
                    }
                }
            }
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
                "format": self?.formatResult ?? NSNull(),
                "undoWorked": self?.undoWorked ?? NSNull(),
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
