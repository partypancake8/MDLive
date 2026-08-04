import SwiftUI
import WebKit
import AppKit
import Combine
import UniformTypeIdentifiers

/// Document window content: optional TOC sidebar + the WebView + error overlay.
/// The model owns the renderer, so the sidebar can drive it and menus can reach it.
struct DocumentView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        HSplitView {
            if model.showOutline {
                OutlineSidebar(items: model.outline) { model.renderer.scrollToAnchor($0) }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 340)
            }
            ZStack(alignment: .topTrailing) {
                WebHost(renderer: model.renderer)
                if let err = model.errorText { ErrorView(text: err) }
                if model.showFind { FindBar(model: model).padding(10) }
            }
            .frame(minWidth: 420)
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
final class PreviewModel: ObservableObject {
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

    private var watcher: FileWatcher?
    private var settingsCancellable: AnyCancellable?
    private var lastGood: String = ""

    init(url: URL) {
        self.url = url
        let baseDir = url.deletingLastPathComponent().path
        renderer.onLink = { LinkRouter.route($0, baseDir: baseDir) }
        renderer.onOutline = { [weak self] items in DispatchQueue.main.async { self?.outline = items } }
        renderer.onScroll = { ScrollMemory.save(url.path, $0) }          // V12 persist
        renderer.initialScrollPct = ScrollMemory.get(url.path)           // V12 restore on first render
        renderer.loadShell()
        load()
        makeWatcher()
        settingsCancellable = Settings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.renderer.applyCurrentSettings(); self?.makeWatcher() }
        }
    }

    deinit { NSLog("MDLive.PreviewModel.deinit %@", url.lastPathComponent) }

    func reload() { load() } // ⌘R

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
        case .changed, .appeared: load()
        case .deleted: errorText = "Can't find this file — it may have been moved or deleted.\n\(url.path)"
        }
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            errorText = "Can't find this file — it may have been moved or deleted.\n\(url.path)"; return
        }
        guard fm.isReadableFile(atPath: url.path) else {
            errorText = "MDLive doesn't have permission to read this file.\n\(url.path)"; return
        }
        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            markdown = s; lastGood = s; errorText = nil; lastUpdated = Date()
            renderer.render(markdown: s, baseDir: url.deletingLastPathComponent().path, scrollPct: 0)
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
