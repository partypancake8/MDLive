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
    private var selectionAfter: Any = NSNull()
    private var keySent: Any = NSNull()
    private var menuOwner: AppDelegate?   // keeps the menu items' target alive

    struct Plan {
        var text: String?
        var selector: String
        var selectWord: String?
        var formats: [String]
        var pasteHTML: String?
        var undo: Bool
        var caretWord: String? = nil
        var key: String? = nil
        var changes: Bool { text?.isEmpty == false || !formats.isEmpty || pasteHTML != nil || undo || key != nil }
    }

    func run(mdPath: String, outPath: String, text: String?, selector: String,
             selectWord: String? = nil, format: String? = nil, pasteHTML: String? = nil, undo: Bool = false,
             caretWord: String? = nil, key: String? = nil) {
        let formats = (format ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let plan = Plan(text: text, selector: selector, selectWord: selectWord,
                        formats: formats, pasteHTML: pasteHTML, undo: undo, caretWord: caretWord, key: key)
        let url = URL(fileURLWithPath: mdPath).standardizedFileURL
        let m = DocumentModel(url: url)
        model = m
        let win = GateWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = m.renderer.webView
        win.orderOut(nil)
        win.makeFirstResponder(m.renderer.webView)
        window = win
        if key != nil {
            // A real key press goes through the app's own main menu, as in a window.
            let owner = AppDelegate()
            menuOwner = owner
            NSApp.mainMenu = owner.makeMainMenu()
            WindowManager.shared.headlessFront = m
            // Key and main (still never ordered in), so nil-target menu items
            // such as Undo find the WebView through the responder chain.
            win.makeKey(); win.makeMain()
        }

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
        if let word = plan.caretWord {
            eval("MDLiveEdit.caretInWord(\(jsonString(word)))") { [weak self] t in
                guard let self else { return }
                self.target = t ?? NSNull()
                self.runKeysAndFormats(plan, afterEdit)
            }
            return
        }
        let typed = plan.formats.isEmpty ? (plan.text.map(jsonString) ?? "null") : "null"
        let place = plan.selectWord.map { "MDLiveEdit.selectText(\(jsonString($0)))" }
            ?? "MDLiveEdit.selfTest(\(jsonString(plan.selector)), \(typed))"
        eval(place) { [weak self] t in
            guard let self else { return }
            self.target = t ?? NSNull()
            self.runKeysAndFormats(plan, afterEdit)
        }
    }

    /// Key presses (MDLIVE_EDIT_KEY, comma separated) and then Format commands,
    /// then record what is selected right after.
    private func runKeysAndFormats(_ plan: Plan, _ afterEdit: @escaping () -> Void) {
        let keys = (plan.key ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let delay = plan.text?.isEmpty == false && !keys.isEmpty ? 0.5 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runKeys(keys, sent: []) { sent in
                guard let self else { return }
                if !keys.isEmpty { self.keySent = sent }
                self.runFormats(plan.formats, results: []) { results in
                    if !plan.formats.isEmpty { self.formatResult = ["commands": plan.formats, "ok": results] }
                    guard !keys.isEmpty || plan.caretWord != nil else { afterEdit(); return }
                    self.eval("String(window.getSelection())") { sel in
                        self.selectionAfter = sel ?? NSNull()
                        afterEdit()
                    }
                }
            }
        }
    }

    private func runKeys(_ keys: [String], sent: [Bool], done: @escaping ([Bool]) -> Void) {
        guard let m = model, let first = keys.first else { done(sent); return }
        let ok = sendKey(first, to: m)
        // The menu command reaches the page through evaluateJavaScript; let it land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.runKeys(Array(keys.dropFirst()), sent: sent + [ok], done: done)
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

    /// Deliver a key combo like "cmd+b" as a real keyDown through NSApp.sendEvent,
    /// so the main menu's key-equivalent path runs exactly as for a keyboard.
    private func sendKey(_ combo: String, to m: DocumentModel) -> Bool {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let ch = parts.last, ch.count == 1 else { return false }
        var mods: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return false
            }
        }
        let codes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                       "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31,
                                       "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        // As a keyboard reports it: Shift turns a letter into a capital.
        let chars = mods.contains(.shift) && ch.first?.isLetter == true ? ch.uppercased() : ch
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window?.windowNumber ?? 0, context: nil,
                                        characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: codes[ch] ?? 0) else { return false }
        NSApp.sendEvent(ev)
        return true
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
        m.renderer.webView.evaluateJavaScript("JSON.stringify(Object.assign({}, window.__mdliveEditInfo || {}, {selectionNow: String(window.getSelection())}))") { [weak self] v, _ in
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
                "keySent": self?.keySent ?? NSNull(),
                "selectionAfter": self?.selectionAfter ?? NSNull(),
                "selectionSettled": info["selectionNow"] ?? NSNull(),
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

/// Offscreen gate window that may be key and main without being shown.
final class GateWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Headless version history gate. Env MDLIVE_HISTORY_SELFTEST=<json out> +
/// MDLIVE_OPEN=<file> + MDLIVE_EDIT_TEXT + MDLIVE_OUTSIDE_TEXT (+ MDLIVE_HISTORY_DIR).
/// Open (records `opened`), type the text at the end of the first paragraph and
/// autosave (`you`), type again ~1 s later (must coalesce into that `you`),
/// write the outside text past DocumentSaver so the watcher reports it
/// (`outside`), then restore the `opened` version the way the Restore button
/// does (`restored`). Writes the version list as JSON and exits 0.
final class HistorySelfTestRunner {
    static let shared = HistorySelfTestRunner()
    private var model: DocumentModel?
    private var window: NSWindow?
    private var done = false
    private var coalesced = false
    private var restored = false
    private var steps: [String] = []

    func run(mdPath: String, outPath: String, text: String, outside: String) {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.typeFirst(text, outside: outside, outPath: outPath) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 38) { [weak self] in
            self?.steps.append("TIMEOUT"); self?.finish(outPath: outPath, code: 2)
        }
    }

    private func type(_ s: String, then next: @escaping () -> Void) {
        let js = (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        model?.renderer.webView.evaluateJavaScript("JSON.stringify(MDLiveEdit.selfTest(\"p\", \(js)))") { _, _ in next() }
    }

    private func count() -> Int { model.map { $0.history.versions(for: $0.url).count } ?? 0 }

    private func typeFirst(_ text: String, outside: String, outPath: String) {
        guard let m = model else { return }
        steps.append("opened:\(count())")
        type(text) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + m.saveDebounce + 0.8) {
                guard let self else { return }
                let afterFirst = self.count()
                self.steps.append("you:\(afterFirst) saves:\(m.saveCount)")
                self.type("!") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + m.saveDebounce + 0.8) {
                        let afterSecond = self.count()
                        self.coalesced = m.saveCount >= 2 && afterSecond == afterFirst
                            && m.history.versions(for: m.url).last?.label == "you"
                        self.steps.append("you2:\(afterSecond) saves:\(m.saveCount)")
                        self.writeOutside(outside, outPath: outPath)
                    }
                }
            }
        }
    }

    private func writeOutside(_ outside: String, outPath: String) {
        guard let m = model else { return }
        do { try Data(outside.utf8).write(to: m.url) } catch { steps.append("outside write failed") }
        waitForOutside(outPath: outPath, tries: 0)
    }

    private func waitForOutside(outPath: String, tries: Int) {
        guard let m = model else { return }
        if m.history.versions(for: m.url).last?.label == "outside" || tries > 80 {
            steps.append("outside:\(count()) tries:\(tries)")
            let opened = m.history.versions(for: m.url).first { $0.label == "opened" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                // The same call the banner's Restore button makes.
                if let v = opened, m.restore(v) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let disk = try? Data(contentsOf: m.url)
                        self.restored = disk != nil && disk == m.history.snapshotData(v.id, for: m.url)
                            && m.history.versions(for: m.url).last?.label == "restored"
                        self.finish(outPath: outPath, code: 0)
                    }
                } else {
                    self.steps.append("restore failed")
                    self.finish(outPath: outPath, code: 0)
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForOutside(outPath: outPath, tries: tries + 1)
        }
    }

    private func finish(outPath: String, code: Int32) {
        if done { return }
        done = true
        let versions: [[String: Any]] = model.map { m in
            m.history.versions(for: m.url).map {
                ["id": $0.id, "timestamp": HistoryStore.iso.string(from: $0.timestamp), "label": $0.label, "bytes": $0.bytes]
            }
        } ?? []
        let out: [String: Any] = ["versions": versions, "coalesced": coalesced, "restored": restored,
                                  "historyDir": model?.history.root.path ?? "", "steps": steps]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        }
        exit(code)
    }
}
