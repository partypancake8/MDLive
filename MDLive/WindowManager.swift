import AppKit
import SwiftUI
import Combine

/// One NSWindow per file URL, deduped. Owns each window's PreviewModel (and thus
/// its FileWatcher), so closing a window tears the watcher down (Step 10).
/// All entry points run on the main thread (AppKit / WK message handlers).
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private struct Doc { let window: NSWindow; let model: PreviewModel }
    private var docs: [URL: Doc] = [:]
    private var emptyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cssWatcher: FileWatcher?            // V17 live-watch of the custom CSS file
    private var cssCancellable: AnyCancellable?

    override init() {
        super.init()
        cssCancellable = Settings.shared.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshCSSWatcher() } }
        refreshCSSWatcher()
    }

    private func refreshCSSWatcher() {
        let path = Settings.shared.customCSSPath
        guard !path.isEmpty else { cssWatcher = nil; return }
        cssWatcher = FileWatcher(fileURL: URL(fileURLWithPath: path)) { [weak self] _ in
            DispatchQueue.main.async { self?.reapplyCSSToAll() }
        }
    }
    private func reapplyCSSToAll() { for d in docs.values { d.model.renderer.applyCurrentSettings() } }

    func showSettings() {
        if let w = settingsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "MDLive Settings"
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(rootView: SettingsView())
        win.delegate = self
        win.center()
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func open(_ url: URL) {
        let key = url.standardizedFileURL
        if let d = docs[key] {
            d.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            marker("focus \(key.path) total=\(docs.count)")
            return
        }
        let model = PreviewModel(url: key)
        let win = makeWindow(title: key.lastPathComponent)
        win.contentViewController = NSHostingController(rootView: DocumentView(model: model))
        win.delegate = self
        // V11: shared frame memory. Restore the saved frame; only size+center if none.
        win.setFrameAutosaveName("MDLiveDoc")
        if !win.setFrameUsingName("MDLiveDoc") {
            win.setContentSize(NSSize(width: 820, height: 720)); win.center()
        }
        clampToScreen(win)
        if Settings.shared.floatByDefault { win.level = .floating } // V14
        docs[key] = Doc(window: win, model: model)
        RecentFiles.add(key)
        emptyWindow?.close()
        emptyWindow = nil
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        marker("open \(key.path) total=\(docs.count)")
    }

    func showEmptyStateIfNeeded() {
        guard docs.isEmpty, emptyWindow == nil else { return }
        let win = makeWindow(title: "MDLive")
        win.contentViewController = NSHostingController(rootView: EmptyStateView())
        win.delegate = self
        win.setContentSize(NSSize(width: 820, height: 720))
        win.center()
        emptyWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: front-window actions (wired to menu items)

    func refreshFront() { front()?.model.reload() }                 // ⌘R
    func toggleOutlineFront() { front()?.model.showOutline.toggle() } // ⌥⌘1 (V10)

    func revealFront() {                                             // ⌘⇧R
        if let url = front()?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func copyFrontPath() {                                          // ⌘L (V13)
        guard let url = front()?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func toggleFloatFront() {                                       // ⌃⌘T (V14)
        guard let w = NSApp.keyWindow else { return }
        w.level = (w.level == .floating) ? .normal : .floating
    }

    func findFront() { front()?.model.openFind() }                  // ⌘F (V8)
    func findStepFront(_ forward: Bool) { front()?.model.findStep(forward) }
    func printFront() { if let m = front()?.model { Exporter.printDoc(m.renderer.webView) } }      // ⌘P (V18)
    func exportPDFFront() { if let m = front()?.model { Exporter.exportPDF(m.renderer.webView) } }
    func exportHTMLFront() { if let m = front()?.model { Exporter.exportHTML(m.renderer.webView) } }

    private func clampToScreen(_ win: NSWindow) {
        guard let vis = (win.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = win.frame
        if !vis.contains(f) {
            f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
            f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
            win.setFrame(f, display: true)
        }
    }

    private func front() -> (url: URL, model: PreviewModel)? {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow,
              let e = docs.first(where: { $0.value.window == w }) else { return nil }
        return (e.key, e.value.model)
    }

    private func makeWindow(title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 360)
        w.center()
        return w
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w == emptyWindow { emptyWindow = nil; return }
        if w == settingsWindow { settingsWindow = nil; return }
        if let key = docs.first(where: { $0.value.window == w })?.key {
            docs.removeValue(forKey: key) // releases model → FileWatcher.deinit
        }
    }

    /// Test hook (env MDLIVE_GUI_MARKER): record window opens for headless checks.
    private func marker(_ line: String) {
        guard let m = ProcessInfo.processInfo.environment["MDLIVE_GUI_MARKER"] else { return }
        let s = line + "\n"
        if let fh = FileHandle(forWritingAtPath: m) {
            fh.seekToEndOfFile(); fh.write(s.data(using: .utf8)!); try? fh.close()
        } else {
            try? s.write(toFile: m, atomically: true, encoding: .utf8)
        }
    }
}

/// Per-file scroll position, persisted to UserDefaults (V12).
enum ScrollMemory {
    private static let key = "mdlive.scrollByPath"
    static func get(_ path: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: key)?[path] as? Double) ?? 0
    }
    static func save(_ path: String, _ pct: Double) {
        var m = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        m[path] = pct
        UserDefaults.standard.set(m, forKey: key)
    }
}

/// Recent files list, backed by UserDefaults (DEC-6: not NSDocumentController,
/// which doesn't populate for a non-document-based app).
enum RecentFiles {
    private static let key = "RecentFiles"
    static let maxCount = 10

    static var urls: [URL] {
        (UserDefaults.standard.array(forKey: key) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
    }
    /// Recents that still exist on disk (home-screen grid filters out moved/deleted).
    static var existing: [URL] { urls.filter { FileManager.default.fileExists(atPath: $0.path) } }

    static func add(_ url: URL) {
        let current = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        UserDefaults.standard.set(computeList(current, adding: url.standardizedFileURL.path), forKey: key)
    }

    /// Pure list update (dedupe, most-recent-first, capped), unit-testable.
    static func computeList(_ current: [String], adding path: String, max: Int = maxCount) -> [String] {
        var paths = current
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        return paths.count > max ? Array(paths.prefix(max)) : paths
    }
}
