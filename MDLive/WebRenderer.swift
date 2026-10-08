import SwiftUI
import WebKit
import AppKit
import Combine
import UniformTypeIdentifiers

/// Document window content: optional TOC sidebar, the editor and/or the WebView
/// (per view mode), the error overlay, and the "changed on disk" conflict bar.
/// The model owns the renderer and the editor, so menus and the sidebar can reach them.
struct DocumentView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.conflict { ConflictBar(model: model) }
            HSplitView {
                if model.showOutline {
                    OutlineSidebar(items: model.outline) { model.renderer.scrollToAnchor($0) }
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 340)
                }
                if model.viewMode != .preview {
                    EditorView(model: model)
                        .frame(minWidth: 280)
                }
                if model.viewMode != .editor {
                    ZStack(alignment: .topTrailing) {
                        WebHost(renderer: model.renderer)
                        if let err = model.errorText { ErrorView(text: err) }
                        if model.showFind { FindBar(model: model).padding(10) }
                    }
                    .frame(minWidth: model.viewMode == .split ? 280 : 420)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onExitCommand { if model.showFind { model.closeFind() } }   // Esc closes find
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in   // V13 drag-in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) else { return }
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

/// Reads the file, owns the renderer + watcher + editor buffer, holds
/// error/outline/sidebar state, and runs autosave. `url` is nil for an untitled
/// buffer until its first save.
final class PreviewModel: NSObject, ObservableObject, NSTextViewDelegate {
    private(set) var url: URL?
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

    // Editing
    @Published var viewMode: ViewMode = ViewMode(rawValue: Settings.shared.viewMode) ?? .preview
    @Published private(set) var editorText: String = ""
    @Published private(set) var isDirty = false
    /// An external change arrived while the buffer had unsaved edits.
    @Published private(set) var conflict = false
    /// nil follows `Settings.autosave`; the edit self-test and tests pin it.
    var autosaveOverride: Bool? = nil
    var autosaveDelay: TimeInterval = 1.0
    var renderDelay: TimeInterval = 0.15
    private(set) var saveCount = 0
    var onSaved: ((_ path: String, _ bytes: Int) -> Void)?
    var onStateChange: (() -> Void)?               // dirty or url changed (window title, edited dot)
    var onURLChange: ((_ old: URL?, _ new: URL) -> Void)?
    var onNeedsLocation: (() -> Void)?             // untitled buffer wants a Save panel
    var askedForLocation = false

    var lineEnding = "\n"
    var trailingNewline = true
    private(set) var lastDiskText: String? = nil
    private var autosaveWork: DispatchWorkItem?
    private var renderWork: DispatchWorkItem?
    private var editorScroll: NSScrollView?
    private(set) weak var textView: NSTextView?

    private var watcher: FileWatcher?
    private var settingsCancellable: AnyCancellable?
    private var lastGood: String = ""

    var autosaveEnabled: Bool { autosaveOverride ?? Settings.shared.autosave }
    var displayName: String { url?.lastPathComponent ?? "Untitled" }
    private var baseDir: String { url?.deletingLastPathComponent().path ?? NSHomeDirectory() }

    init(url: URL?) {
        self.url = url?.standardizedFileURL
        super.init()
        renderer.onLink = { [weak self] href in LinkRouter.route(href, baseDir: self?.baseDir ?? NSHomeDirectory()) }
        renderer.onOutline = { [weak self] items in DispatchQueue.main.async { self?.outline = items } }
        renderer.onScroll = { [weak self] pct in if let p = self?.url?.path { ScrollMemory.save(p, pct) } }  // V12 persist
        if let u = self.url { renderer.initialScrollPct = ScrollMemory.get(u.path) }                       // V12 restore
        renderer.loadShell()
        if self.url != nil { load() } else { viewMode = .split; renderer.render(markdown: "", baseDir: baseDir, scrollPct: 0) }
        makeWatcher()
        settingsCancellable = Settings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.renderer.applyCurrentSettings(); self?.makeWatcher(); self?.applyEditorAppearance()
                self?.onStateChange?()
            }
        }
    }

    deinit { NSLog("MDLive.PreviewModel.deinit %@", url?.lastPathComponent ?? "untitled") }

    /// ⌘R: with unsaved edits re-render the buffer, otherwise re-read the file.
    func reload() { if isDirty { renderNow() } else { load() } }

    // Find (V8)
    func runFind() { renderer.find(findQuery) { [weak self] c, cur in DispatchQueue.main.async { self?.findCount = c; self?.findCurrent = cur } } }
    func findStep(_ forward: Bool) { renderer.findNext(forward: forward) { [weak self] c, cur in DispatchQueue.main.async { self?.findCount = c; self?.findCurrent = cur } } }
    func openFind() {
        if viewMode == .editor, let tv = textView {
            let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
            tv.performTextFinderAction(item)
            return
        }
        showFind = true
    }
    func closeFind() { showFind = false; findQuery = ""; findCount = 0; findCurrent = 0; renderer.clearFind() }

    private func makeWatcher() {
        guard let url else { watcher = nil; return }
        watcher = FileWatcher(fileURL: url,
                              enabled: Settings.shared.autoRefresh,
                              pollInterval: Settings.shared.pollInterval) { [weak self] e in self?.handle(e) }
    }

    /// Watcher events (internal so tests can drive the conflict path directly).
    func handle(_ event: FileWatcher.Event) {
        switch event {
        case .changed, .appeared: externalChange()
        case .deleted: errorText = "Can't find this file, it may have been moved or deleted.\n\(url?.path ?? "")"
        }
    }

    private func externalChange() {
        guard let url, let disk = try? String(contentsOf: url, encoding: .utf8) else { load(); return }
        if disk == lastDiskText { errorText = nil; return }   // our own write, or no real change
        if isDirty {
            conflict = true                                    // keep the buffer; the bar asks
            autosaveWork?.cancel()
            return
        }
        load()
    }

    /// Conflict bar: take the disk version.
    func reloadFromDisk() { conflict = false; isDirty = false; load(); onStateChange?() }
    /// Conflict bar: keep the buffer; it wins on the next save.
    func keepMine() {
        conflict = false
        if let url, let disk = try? String(contentsOf: url, encoding: .utf8) { lastDiskText = disk }
        scheduleAutosave()
    }

    private func load() {
        guard let url else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            errorText = "Can't find this file, it may have been moved or deleted.\n\(url.path)"; return
        }
        guard fm.isReadableFile(atPath: url.path) else {
            errorText = "MDLive doesn't have permission to read this file.\n\(url.path)"; return
        }
        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            markdown = s; lastGood = s; errorText = nil; lastUpdated = Date()
            lastDiskText = s
            let fmt = DiskText.detect(s)
            lineEnding = fmt.lineEnding; trailingNewline = fmt.trailingNewline
            setEditorText(DiskText.normalize(s))
            renderer.render(markdown: s, baseDir: baseDir, scrollPct: 0)
        } catch {
            if lastGood.isEmpty { errorText = "This file isn't readable as text (UTF-8).\n\(url.path)" }
        }
    }

    // MARK: editor buffer

    /// The text view, created once and kept for the model's life so undo history
    /// survives view-mode switches.
    func editorScrollView() -> NSScrollView {
        if let s = editorScroll { return s }
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 10, height: 12)
        tv.textContainer?.widthTracksTextView = true      // soft wrap
        tv.isHorizontallyResizable = false
        tv.string = editorText
        tv.delegate = self
        tv.setAccessibilityLabel("Markdown editor")
        editorScroll = scroll
        textView = tv
        applyEditorAppearance()
        return scroll
    }

    func applyEditorAppearance() {
        guard let scroll = editorScroll, let tv = textView else { return }
        let dark = Settings.shared.theme != "light"
        scroll.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let bg = dark ? NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1) : NSColor.textBackgroundColor
        tv.backgroundColor = bg
        scroll.backgroundColor = bg
        tv.textColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor.textColor
        tv.insertionPointColor = dark ? .white : .black
        let size = 13 * CGFloat(min(3.0, max(0.5, Settings.shared.fontScale)))
        tv.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        tv.typingAttributes[.font] = tv.font
        tv.typingAttributes[.foregroundColor] = tv.textColor
    }

    /// Replace the buffer programmatically (load, revert): not an edit, clears undo.
    private func setEditorText(_ s: String) {
        editorText = s
        if let tv = textView, tv.string != s {
            let sel = tv.selectedRange()
            tv.string = s
            let len = (s as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            tv.undoManager?.removeAllActions(withTarget: tv.textStorage as Any)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        userEdited(tv.string)
    }

    /// Every keystroke lands here: mark dirty, re-render after ~150 ms, autosave after ~1 s.
    func userEdited(_ text: String) {
        editorText = text
        let wasDirty = isDirty
        isDirty = true
        if !wasDirty { onStateChange?() }
        renderWork?.cancel()
        let r = DispatchWorkItem { [weak self] in self?.renderNow() }
        renderWork = r
        DispatchQueue.main.asyncAfter(deadline: .now() + renderDelay, execute: r)
        scheduleAutosave()
    }

    private func renderNow() {
        markdown = editorText; lastUpdated = Date()
        renderer.render(markdown: editorText, baseDir: baseDir, scrollPct: 0)
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        guard autosaveEnabled else { return }
        let w = DispatchWorkItem { [weak self] in self?.autosaveFired() }
        autosaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: w)
    }

    private func autosaveFired() {
        guard isDirty, !conflict else { return }
        if url == nil {
            if !askedForLocation { askedForLocation = true; onNeedsLocation?() }
            return
        }
        _ = try? save()
    }

    /// Close, quit, resign-key and mode switch: write pending edits now.
    func flushAutosave() {
        autosaveWork?.cancel(); autosaveWork = nil
        guard autosaveEnabled, isDirty, !conflict, url != nil else { return }
        _ = try? save()
    }

    /// Write the buffer to `url` atomically, keeping the file's line endings and
    /// trailing newline. The watcher is told so it does not echo the write back.
    @discardableResult
    func save() throws -> Int {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try write(to: url)
    }

    @discardableResult
    private func write(to target: URL) throws -> Int {
        autosaveWork?.cancel(); autosaveWork = nil
        let out = DiskText.encode(editorText, lineEnding: lineEnding, trailingNewline: trailingNewline)
        let data = Data(out.utf8)
        let doWrite = { try data.write(to: target, options: .atomic) }
        if let w = watcher, target == url { try w.performSelfWrite(doWrite) } else { try doWrite() }
        lastDiskText = out
        lastGood = out
        isDirty = false
        conflict = false
        errorText = nil
        saveCount += 1
        onStateChange?()
        onSaved?(target.path, data.count)
        return data.count
    }

    /// Save As (and the first save of an untitled buffer): write, then move this
    /// model (watcher, title, window key) to the new URL.
    @discardableResult
    func saveAs(to newURL: URL) throws -> Int {
        let target = newURL.standardizedFileURL
        let old = url
        let bytes = try write(to: target)
        url = target
        if old == nil { renderer.initialScrollPct = 0 }
        makeWatcher()
        RecentFiles.add(target)
        onURLChange?(old, target)
        onStateChange?()
        renderNow()
        return bytes
    }

    /// File > Revert to Saved: drop the buffer and reload the file.
    func revertToSaved() {
        autosaveWork?.cancel(); autosaveWork = nil
        guard url != nil else { return }
        isDirty = false; conflict = false
        load()
        textView?.undoManager?.removeAllActions()
        onStateChange?()
    }

    /// Discard without saving (close prompt "Don't Save").
    func discardChanges() { autosaveWork?.cancel(); autosaveWork = nil; isDirty = false; conflict = false }

    func setViewMode(_ mode: ViewMode, persist: Bool = true) {
        flushAutosave()
        viewMode = mode
        if persist { Settings.shared.viewMode = mode.rawValue }
        if mode != .preview, let tv = textView {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }
}

/// "file changed on disk" bar: non-blocking, keeps both sides until the user picks.
struct ConflictBar: View {
    @ObservedObject var model: PreviewModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("This file changed on disk while you have unsaved edits.")
            Spacer()
            Button("Reload") { model.reloadFromDisk() }
            Button("Keep Mine") { model.keepMine() }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.yellow.opacity(0.15))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File changed on disk")
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
                Text("MDLive previews and edits Markdown, and refreshes when the file changes on disk.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Open File…") { Self.openPanel() }
                    Button("New File") { WindowManager.shared.newDocument() }
                }
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
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), .plainText].compactMap { $0 }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for u in panel.urls { WindowManager.shared.open(u) } }
    }
}
