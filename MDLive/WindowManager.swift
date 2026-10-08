import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// One NSWindow per file URL, deduped. Owns each window's PreviewModel (and thus
/// its FileWatcher), so closing a window tears the watcher down (Step 10).
/// Untitled buffers live in `untitled` until their first save moves them into
/// `docs` under the new URL; Save As re-keys the same way.
/// All entry points run on the main thread (AppKit / WK message handlers).
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private struct Doc { let window: NSWindow; let model: PreviewModel }
    private var docs: [URL: Doc] = [:]
    private var untitled: [Doc] = []
    private var untitledCounter = 0
    private var allDocs: [Doc] { Array(docs.values) + untitled }
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
    private func reapplyCSSToAll() { for d in allDocs { d.model.renderer.applyCurrentSettings() } }

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
        let win = makeDocWindow(model: model)
        RecentFiles.add(key)
        present(win)
        marker("open \(key.path) total=\(docs.count)")
    }

    /// File > New (Cmd+N): an untitled buffer in split mode. Its first autosave
    /// or Cmd+S asks where to put it.
    @discardableResult
    func newDocument() -> PreviewModel {
        let model = PreviewModel(url: nil)
        untitledCounter += 1
        let win = makeDocWindow(model: model)
        if untitledCounter > 1 { win.title = "Untitled \(untitledCounter)" }
        present(win)
        marker("new untitled total=\(untitled.count)")
        return model
    }

    private func makeDocWindow(model: PreviewModel) -> NSWindow {
        let win = makeWindow(title: model.displayName)
        win.contentViewController = NSHostingController(rootView: DocumentView(model: model))
        // V11: shared frame memory. Restore the saved frame; only size+center if none.
        win.setFrameAutosaveName("MDLiveDoc")
        if !win.setFrameUsingName("MDLiveDoc") {
            win.setContentSize(NSSize(width: 820, height: 720)); win.center()
        }
        clampToScreen(win)
        if Settings.shared.floatByDefault { win.level = .floating } // V14
        register(model, window: win)
        return win
    }

    private func present(_ win: NSWindow) {
        emptyWindow?.close()
        emptyWindow = nil
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Track a model + window and wire its save callbacks. Internal so tests can
    /// register an offscreen window without putting anything on screen.
    func register(_ model: PreviewModel, window win: NSWindow) {
        win.delegate = self
        let doc = Doc(window: win, model: model)
        if let u = model.url { docs[u.standardizedFileURL] = doc } else { untitled.append(doc) }
        model.onURLChange = { [weak self, weak model] old, new in
            guard let self, let model else { return }
            self.rekey(model, from: old, to: new)
        }
        model.onStateChange = { [weak self, weak model, weak win] in
            guard let model, let win else { return }
            self?.updateChrome(win, model)
        }
        model.onNeedsLocation = { [weak self, weak model] in
            guard let self, let model else { return }
            self.runSavePanel(for: model, completion: nil)
        }
        updateChrome(win, model)
    }

    func unregister(window win: NSWindow) {
        if let key = docs.first(where: { $0.value.window == win })?.key { docs.removeValue(forKey: key) }
        untitled.removeAll { $0.window == win }
    }

    /// The window currently showing `url`, if any (dedupe lookup).
    func window(for url: URL) -> NSWindow? { docs[url.standardizedFileURL]?.window }

    /// Save As / first save moved a model to a new URL: move its dict key so
    /// one-window-per-file dedupe follows the file. If another window already
    /// showed the target, that window's content was just overwritten, so close it.
    func rekey(_ model: PreviewModel, from old: URL?, to new: URL) {
        let newKey = new.standardizedFileURL
        var doc: Doc?
        if let old, let d = docs[old.standardizedFileURL], d.model === model {
            docs.removeValue(forKey: old.standardizedFileURL); doc = d
        } else if let i = untitled.firstIndex(where: { $0.model === model }) {
            doc = untitled.remove(at: i)
        } else if let e = docs.first(where: { $0.value.model === model }) {
            docs.removeValue(forKey: e.key); doc = e.value
        }
        guard let doc else { return }
        if let other = docs[newKey], other.model !== model {
            docs.removeValue(forKey: newKey)
            other.model.discardChanges()
            other.window.close()
        }
        docs[newKey] = doc
        updateChrome(doc.window, model)
        marker("rekey \(old?.path ?? "untitled") -> \(newKey.path)")
    }

    private func updateChrome(_ win: NSWindow, _ model: PreviewModel) {
        if let u = model.url { win.title = u.lastPathComponent; win.representedURL = u }
        // With autosave on, edits are saved within a second, so no edited dot.
        win.isDocumentEdited = model.isDirty && !(model.autosaveEnabled && model.url != nil)
    }

    // MARK: saving

    func saveFront() {
        guard let m = frontModel() else { return }
        if m.url == nil { runSavePanel(for: m, completion: nil); return }
        do { try m.save() } catch { presentError(error) }
    }
    func saveAsFront() { if let m = frontModel() { runSavePanel(for: m, completion: nil) } }
    func revertFront() { frontModel()?.revertToSaved() }
    func setViewModeFront(_ mode: ViewMode) {
        if let m = frontModel() { m.setViewMode(mode) } else { Settings.shared.viewMode = mode.rawValue }
    }

    private func windowFor(_ model: PreviewModel) -> NSWindow? { allDocs.first { $0.model === model }?.window }

    /// NSSavePanel as a sheet on the model's window (or app-modal without one).
    func runSavePanel(for model: PreviewModel, completion: ((Bool) -> Void)?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = model.url?.lastPathComponent ?? ((windowFor(model)?.title ?? "Untitled") + ".md")
        if let dir = model.url?.deletingLastPathComponent() { panel.directoryURL = dir }
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak model] resp in
            guard let model else { completion?(false); return }
            guard resp == .OK, let url = panel.url else { completion?(false); return }
            do { try model.saveAs(to: url); completion?(true) } catch { self?.presentError(error); completion?(false) }
        }
        if let win = windowFor(model), win.isVisible {
            panel.beginSheetModal(for: win, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func presentError(_ error: Error) {
        let a = NSAlert(error: error)
        a.runModal()
    }

    /// Ask Save / Don't Save / Cancel for a dirty buffer that autosave will not
    /// cover (autosave off, or never saved). Returns true when it is safe to close.
    private func confirmClose(_ model: PreviewModel, window: NSWindow?) -> Bool {
        guard model.isDirty, !(model.autosaveEnabled && model.url != nil && !model.conflict) else { return true }
        let a = NSAlert()
        a.messageText = "Do you want to save the changes you made to \(window?.title ?? model.displayName)?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if model.url == nil {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "md")].compactMap { $0 }
                panel.allowsOtherFileTypes = true
                panel.nameFieldStringValue = (window?.title ?? "Untitled") + ".md"
                guard panel.runModal() == .OK, let url = panel.url else { return false }
                do { try model.saveAs(to: url) } catch { presentError(error); return false }
                return true
            }
            do { try model.save(); return true } catch { presentError(error); return false }
        case .alertSecondButtonReturn:
            return false
        default:
            model.discardChanges(); return true
        }
    }

    /// App quit: autosave everything, then prompt for anything autosave can't cover.
    func prepareToQuit() -> Bool {
        for d in allDocs { d.model.flushAutosave() }
        for d in allDocs where !confirmClose(d.model, window: d.window) { return false }
        return true
    }

    func showEmptyStateIfNeeded() {
        guard docs.isEmpty, untitled.isEmpty, emptyWindow == nil else { return }
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

    private func frontModel() -> PreviewModel? {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return allDocs.first { $0.window == w }?.model
    }

    func refreshFront() { frontModel()?.reload() }                 // ⌘R
    func toggleOutlineFront() { frontModel()?.showOutline.toggle() } // ⌥⌘1 (V10)

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

    func findFront() { frontModel()?.openFind() }                   // ⌘F (V8)
    func findStepFront(_ forward: Bool) { frontModel()?.findStep(forward) }
    func printFront() { if let m = frontModel() { Exporter.printDoc(m.renderer.webView) } }      // ⌘P (V18)
    func exportPDFFront() { if let m = frontModel() { Exporter.exportPDF(m.renderer.webView) } }
    func exportHTMLFront() { if let m = frontModel() { Exporter.exportHTML(m.renderer.webView) } }

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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let d = allDocs.first(where: { $0.window == sender }) else { return true }
        d.model.flushAutosave()
        return confirmClose(d.model, window: sender)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let w = notification.object as? NSWindow,
              let d = allDocs.first(where: { $0.window == w }) else { return }
        d.model.flushAutosave()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w == emptyWindow { emptyWindow = nil; return }
        if w == settingsWindow { settingsWindow = nil; return }
        allDocs.first(where: { $0.window == w })?.model.flushAutosave()
        unregister(window: w) // releases model → FileWatcher.deinit
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
