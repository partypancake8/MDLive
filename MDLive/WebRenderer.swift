import SwiftUI
import WebKit
import AppKit
import Combine
import UniformTypeIdentifiers

/// Document window content: optional TOC sidebar + the WebView + error overlay.
/// The model owns the renderer, so the sidebar can drive it and menus can reach it.
struct DocumentView: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HSplitView {
            if model.showOutline {
                OutlineSidebar(items: model.outline) { model.renderer.scrollToAnchor($0) }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 340)
            }
            VStack(spacing: 0) {
                if let v = model.previewing { HistoryBanner(model: model, version: v) }
                ZStack(alignment: .topTrailing) {
                    WebHost(renderer: model.renderer)
                    if let err = model.errorText { ErrorView(text: err) }
                    if model.showFind { FindBar(model: model).padding(10) }
                }
            }
            .frame(minWidth: 420)
            if model.showHistory {
                HistorySidebar(model: model)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onExitCommand { if model.showFind { model.closeFind() } }   // Esc closes find
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in   // V13 drag-in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["md", "markdown"].contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { WindowManager.shared.open(url) }
                }
            }
            return true
        }
    }
}

/// Hosts the model-owned WKWebView. The model drives rendering; nothing to update here.
struct WebHost: NSViewRepresentable {
    let renderer: WebKitRenderer
    func makeNSView(context: Context) -> WKWebView { renderer.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Reads the file, owns the renderer + watcher, holds error/outline/sidebar state.
final class DocumentModel: ObservableObject {
    let url: URL
    let renderer = WebKitRenderer()
    @Published var markdown: String = ""
    @Published var errorText: String? = nil
    @Published var outline: [OutlineItem] = []
    @Published var showOutline: Bool = false
    @Published var lastUpdated: Date? = nil
    // Find (V8)
    @Published var showFind = false
    @Published var findQuery = ""
    @Published var findCount = 0
    @Published var findCurrent = 0
    // Version history: the sidebar, its list (newest first) and the version
    // being looked at (read only) while one is selected.
    @Published var showHistory = false { didSet { if showHistory { refreshVersions() } else { backToCurrent() } } }
    @Published private(set) var versions: [HistoryVersion] = []
    @Published private(set) var previewing: HistoryVersion? = nil
    let history: HistoryStore

    private var watcher: FileWatcher?
    private var settingsCancellable: AnyCancellable?
    private var lastGood: String = ""

    // In-place editing + autosave. The page posts the full new Markdown on each
    // real change; it is written ~1 s after the last one. `diskText` is what the
    // file holds as far as MDLive knows (last read or last own write).
    var saveDebounce: TimeInterval = 1.0
    private(set) var saveCount = 0
    private(set) var bytesWritten = 0
    private(set) var hasPendingSave = false
    private var pendingText: String?
    private var saveWork: DispatchWorkItem?
    private var diskText: String?
    private var terminateObserver: NSObjectProtocol?

    init(url: URL, history: HistoryStore = .shared) {
        self.url = url
        self.history = history
        let baseDir = url.deletingLastPathComponent().path
        renderer.onLink = { LinkRouter.route($0, baseDir: baseDir) }
        renderer.onOutline = { [weak self] items in DispatchQueue.main.async { self?.outline = items } }
        renderer.onScroll = { ScrollMemory.save(url.path, $0) }          // V12 persist
        renderer.initialScrollPct = ScrollMemory.get(url.path)           // V12 restore on first render
        renderer.editingEnabled = true
        renderer.onEdit = { [weak self] text in self?.editDidChange(text) }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flushSave()
        }
        renderer.loadShell()
        load(label: .opened)
        makeWatcher()
        settingsCancellable = Settings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.renderer.applyCurrentSettings(); self?.makeWatcher() }
        }
    }

    deinit {
        flushSave()
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        NSLog("MDLive.DocumentModel.deinit %@", url.lastPathComponent)
    }

    func reload() { flushSave(); load(label: .outside) } // ⌘R

    // MARK: autosave

    /// A real content change from the page: (re)start the debounce.
    func editDidChange(_ text: String) {
        pendingText = text
        hasPendingSave = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounce, execute: work)
    }

    /// Write the pending edit now (debounce fired, window closing, app quitting).
    func flushSave() {
        saveWork?.cancel(); saveWork = nil
        hasPendingSave = false
        guard let text = pendingText else { return }
        pendingText = nil
        let original = diskText ?? ""
        let out = DocumentSaver.conform(text, to: original)
        if out == original { return } // edited and put back: nothing to write
        commit(out, label: .you)
    }

    /// The one write path: autosave and Restore both come through here, so the
    /// watcher, the model and the history log all see the same thing.
    @discardableResult
    private func commit(_ out: String, label: HistoryStore.Label) -> Bool {
        do {
            bytesWritten = try DocumentSaver.write(out, to: url)
            watcher?.noteSelfWrite()
            diskText = out; markdown = out; lastGood = out
            saveCount += 1
            history.record(out, for: url, label: label)
            if showHistory { refreshVersions() }
            return true
        } catch {
            NSLog("MDLive: autosave failed for %@: %@", url.path, error.localizedDescription)
            return false
        }
    }

    // MARK: version history

    func refreshVersions() { versions = history.versions(for: url).reversed() }

    /// Show an old version read only (no editing while it is up).
    func preview(_ v: HistoryVersion) {
        guard let text = history.snapshot(v.id, for: url) else { return }
        flushSave()
        previewing = v
        renderer.webView.evaluateJavaScript("disableEditing();", completionHandler: nil)
        renderer.render(markdown: text, baseDir: url.deletingLastPathComponent().path, scrollPct: 0)
    }

    /// Leave the preview: the live file again, editable.
    func backToCurrent() {
        guard previewing != nil else { return }
        previewing = nil
        renderer.render(markdown: markdown, baseDir: url.deletingLastPathComponent().path, scrollPct: 0)
        renderer.webView.evaluateJavaScript("enableEditing();", completionHandler: nil)
    }

    /// Restore: write the version's exact bytes through the normal save path
    /// (recorded as `restored`), then show the live file. No prompt; the
    /// version it replaced stays in the list.
    @discardableResult
    func restore(_ v: HistoryVersion) -> Bool {
        guard let text = history.snapshot(v.id, for: url) else { return false }
        saveWork?.cancel(); saveWork = nil
        pendingText = nil; hasPendingSave = false
        let ok = text == diskText || commit(text, label: .restored)
        previewing = nil
        renderer.render(markdown: markdown, baseDir: url.deletingLastPathComponent().path, scrollPct: 0)
        renderer.webView.evaluateJavaScript("enableEditing();", completionHandler: nil)
        refreshVersions()
        return ok
    }

    /// Format menu command (bold, heading2, bulletList, link, ...). The menu, its
    /// shortcuts and the headless gate all come through here into the page.
    func format(_ command: String, arg: String? = nil, completion: ((Bool) -> Void)? = nil) {
        func js(_ s: String) -> String { (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\"" }
        let call = "MDLiveEdit.format(\(js(command)), \(arg.map(js) ?? "null"))"
        renderer.webView.evaluateJavaScript(call) { v, _ in completion?((v as? Bool) ?? false) }
    }

    // Find (V8)
    func runFind() { renderer.find(findQuery) { [weak self] c, cur in DispatchQueue.main.async { self?.findCount = c; self?.findCurrent = cur } } }
    func findStep(_ forward: Bool) { renderer.findNext(forward: forward) { [weak self] c, cur in DispatchQueue.main.async { self?.findCount = c; self?.findCurrent = cur } } }
    func openFind() { showFind = true }
    func closeFind() { showFind = false; findQuery = ""; findCount = 0; findCurrent = 0; renderer.clearFind() }

    private func makeWatcher() {
        watcher = FileWatcher(fileURL: url,
                              enabled: Settings.shared.autoRefresh,
                              pollInterval: Settings.shared.pollInterval) { [weak self] e in self?.handle(e) }
    }

    private func handle(_ event: FileWatcher.Event) {
        switch event {
        case .changed, .appeared:
            // An edit waiting to be saved wins over an outside change (last writer).
            if hasPendingSave { return }
            // Our own autosave coming back through the watcher: nothing to re-render.
            if let d = diskText, let now = try? String(contentsOf: url, encoding: .utf8), now == d { return }
            load(label: .outside)
        case .deleted: errorText = "Can't find this file, it may have been moved or deleted.\n\(url.path)"
        }
    }

    private func load(label: HistoryStore.Label) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            errorText = "Can't find this file, it may have been moved or deleted.\n\(url.path)"; return
        }
        guard fm.isReadableFile(atPath: url.path) else {
            errorText = "MDLive doesn't have permission to read this file.\n\(url.path)"; return
        }
        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            markdown = s; lastGood = s; diskText = s; errorText = nil; lastUpdated = Date()
            history.record(s, for: url, label: label)   // skipped when equal to the newest version
            if showHistory { refreshVersions() }
            // While an old version is on screen, the live file updates underneath it.
            if previewing == nil {
                renderer.render(markdown: s, baseDir: url.deletingLastPathComponent().path, scrollPct: 0)
            }
        } catch {
            if lastGood.isEmpty { errorText = "This file isn't readable as text (UTF-8).\n\(url.path)" }
        }
    }
}

/// Routes clicked links (DEC-11). `classify` is pure (testable); `route` acts on it.
enum LinkRoute: Equatable {
    case web(URL)            // http/https/mailto → default app
    case localMarkdown(URL)  // local .md/.markdown → new MDLive window
    case localOther(URL)     // other local file → system default app
}

enum LinkRouter {
    static func classify(_ href: String, baseDir: String) -> LinkRoute? {
        if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            return .web(url)
        }
        let path = href.hasPrefix("/") ? href : (baseDir as NSString).appendingPathComponent(href)
        let fileURL = URL(fileURLWithPath: path)
        if ["md", "markdown"].contains(fileURL.pathExtension.lowercased()) {
            return .localMarkdown(fileURL)
        }
        return .localOther(fileURL)
    }

    static func route(_ href: String, baseDir: String) {
        switch classify(href, baseDir: baseDir) {
        case .web(let u), .localOther(let u): NSWorkspace.shared.open(u)
        case .localMarkdown(let u): DispatchQueue.main.async { WindowManager.shared.open(u) }
        case .none: break
        }
    }
}

struct ErrorView: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).font(.system(.body, design: .monospaced)).multilineTextAlignment(.center).textSelection(.enabled)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09))
        .accessibilityLabel("Error: \(text)")
    }
}

struct EmptyStateView: View {
    @State private var recents: [URL] = []

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Text("Open a Markdown file").font(.title2).bold()
                Text("MDLive previews Markdown and refreshes when the file changes on disk.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open File…") { Self.openPanel() }
            }
            .padding(.top, 12)
            if !recents.isEmpty {
                Divider()
                RecentFilesGrid(urls: recents)   // fills remaining width + height
            } else {
                Spacer()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09))
        .onAppear { recents = RecentFiles.existing }   // fresh each time the home screen shows
    }

    static func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for u in panel.urls { WindowManager.shared.open(u) } }
    }
}
