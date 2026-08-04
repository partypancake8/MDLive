import Foundation
import WebKit

/// Owns one WKWebView + the bundled markdown-it shell. Shared by the SwiftUI
/// view layer (WebRenderer) and the headless SelfTestRunner. Render-before-ready
/// is queued and flushed when the JS `ready` handshake fires (PRD §5.1/§5.3).
final class WebKitRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    var onLink: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onOutline: (([OutlineItem]) -> Void)?   // V10
    var onScroll: ((Double) -> Void)?           // V12
    var initialScrollPct: Double = 0            // V12 — applied on the first render
    private var didFirstRender = false
    private let imageHandler = ImageSchemeHandler()

    private var ready = false
    private var latest: (markdown: String, baseDir: String, scrollPct: Double)?

    override init() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        config.setURLSchemeHandler(imageHandler, forURLScheme: "mdlive-img") // DEC-8/DEC-13
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        ucc.add(self, name: "ready") // mandatory handshake (§5.3)
        ucc.add(self, name: "link")
        ucc.add(self, name: "outline")
        ucc.add(self, name: "scroll")
        webView.navigationDelegate = self
    }

    /// Load the bundled offline shell (DEC-8a: read-access scoped to web/).
    func loadShell() {
        guard let webDir = Bundle.main.url(forResource: "web", withExtension: nil),
              let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
                ?? Optional(webDir.appendingPathComponent("index.html"))
        else {
            NSLog("MDLive: bundled web/ shell missing")
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: webDir)
    }

    /// Render markdown into the live DOM (DEC-9 — no reload). Queues if not ready.
    func render(markdown: String, baseDir: String, scrollPct: Double) {
        latest = (markdown, baseDir, scrollPct)
        imageHandler.docDir = baseDir // DEC-13: scope image reads to this doc's dir
        if ready { flush() }
    }

    private func flush() {
        guard let l = latest else { return }
        if let marker = ProcessInfo.processInfo.environment["MDLIVE_GUI_MARKER"] {
            let line = "rendered \(l.markdown.count) chars baseDir=\(l.baseDir)\n"
            if let fh = FileHandle(forWritingAtPath: marker) { fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close() }
            else { try? line.write(toFile: marker, atomically: true, encoding: .utf8) }
        }
        let mdJSON = jsString(l.markdown)
        let dirJSON = jsString(l.baseDir)
        let initial = !didFirstRender // V12: first render restores stored scroll; refreshes keep current
        let pct = initial ? initialScrollPct : l.scrollPct
        didFirstRender = true
        let call = "render(\(mdJSON), {baseDir: \(dirJSON), scrollPct: \(pct), initial: \(initial)});"
        webView.evaluateJavaScript(call, completionHandler: nil)
    }

    /// Push current Settings to the view (DEC-V2): theme/width/custom-CSS/math via
    /// JS `applySettings`, zoom via native `pageZoom`. Idempotent; safe to call on
    /// `ready` and on every Settings change.
    func applyCurrentSettings() {
        guard ready else { return }
        let s = Settings.shared
        var css = ""
        if !s.customCSSPath.isEmpty {
            css = (try? String(contentsOfFile: s.customCSSPath, encoding: .utf8)) ?? "" // missing/bad → ignored
        }
        webView.evaluateJavaScript("applySettings(\(s.jsOptsJSON(customCSS: css)));", completionHandler: nil)
        webView.pageZoom = CGFloat(min(3.0, max(0.5, s.fontScale)))
    }

    /// Read back rendered content for the self-test gate (PRD §6).
    func readback(_ completion: @escaping (String?) -> Void) {
        let js = "(function(){var c=document.getElementById('content');var html=c.innerHTML,text=c.innerText;var fr=(typeof find==='function')?find('e'):{count:0};if(typeof clearFind==='function')clearFind();var ser=(typeof serializeForExport==='function')?serializeForExport():'';return JSON.stringify({text:text,html:html,count:window.__mdliveRenderCount||0,theme:document.documentElement.getAttribute('data-theme'),contentMax:document.documentElement.style.getPropertyValue('--content-max'),math:!!window.__mathEnabled,userCSS:(document.getElementById('user-css')||{}).textContent||'',outlineLen:(window.__mdliveOutline||[]).length,findCount:fr.count,exportHasStyle:(ser.indexOf('<style>')>=0&&ser.indexOf('<h1')>=0),exportLen:ser.length});})()"
        webView.evaluateJavaScript(js) { value, _ in
            completion(value as? String)
        }
    }

    // MARK: WKScriptMessageHandler
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "ready":
            ready = true
            flush()
            applyCurrentSettings()
            onReady?()
        case "link":
            if let href = message.body as? String { onLink?(href) }
        case "outline":
            if let arr = message.body as? [[String: Any]] {
                onOutline?(arr.compactMap { d in
                    guard let l = d["level"] as? Int, let t = d["text"] as? String, let i = d["id"] as? String else { return nil }
                    return OutlineItem(level: l, text: t, anchor: i)
                })
            }
        case "scroll":
            if let p = message.body as? Double { onScroll?(p) }
        default: break
        }
    }

    // MARK: find (V8/DEC-V13), outline scroll (V10), scroll read (V12)
    func find(_ query: String, completion: @escaping (_ count: Int, _ current: Int) -> Void) {
        webView.evaluateJavaScript("JSON.stringify(find(\(jsString(query))))") { v, _ in
            Self.parseFind(v, completion) }
    }
    func findNext(forward: Bool, completion: @escaping (_ count: Int, _ current: Int) -> Void) {
        webView.evaluateJavaScript("JSON.stringify(findNext(\(forward)))") { v, _ in
            Self.parseFind(v, completion) }
    }
    func clearFind() { webView.evaluateJavaScript("clearFind()", completionHandler: nil) }
    func scrollToAnchor(_ id: String) { webView.evaluateJavaScript("scrollToAnchor(\(jsString(id)))", completionHandler: nil) }

    private static func parseFind(_ v: Any?, _ completion: (Int, Int) -> Void) {
        let r = decodeFind(v as? String ?? "")
        completion(r.count, r.current)
    }

    /// Decode the JSON returned by JS `find`/`findNext` (internal → unit-testable).
    static func decodeFind(_ json: String) -> (count: Int, current: Int) {
        if let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
            return (d["count"] as? Int ?? 0, d["current"] as? Int ?? 0)
        }
        return (0, 0)
    }

    private func jsString(_ s: String) -> String {
        let data = try? JSONEncoder().encode(s)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

/// Serves local images for `mdlive-img://<percent-encoded-abs-path>`, validated
/// to live under the open file's directory (DEC-8/DEC-13). Minimal for the
/// hello-world slice; full directory-prefix validation lands in Step 5.
/// A heading for the TOC sidebar (V10). `anchor` is the heading id (unique — the
/// anchor plugin de-dupes slugs).
struct OutlineItem: Identifiable, Hashable {
    let level: Int
    let text: String
    let anchor: String
    var id: String { anchor }
}

final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    var docDir: String?

    /// DEC-13: decode the `mdlive-img://` URL and return the canonical path ONLY
    /// if it lives under `docDir` (symlinks resolved); else nil (reject). Static +
    /// pure so it's unit-testable without a WKWebView.
    static func resolve(rawURL: String, docDir: String?) -> String? {
        let prefix = "mdlive-img://"
        guard rawURL.hasPrefix(prefix),
              let path = String(rawURL.dropFirst(prefix.count)).removingPercentEncoding,
              let dir = docDir else { return nil }
        let canon = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let canonDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().standardizedFileURL.path
        guard canon == canonDir || canon.hasPrefix(canonDir + "/") else { return nil }
        return canon
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let path = Self.resolve(rawURL: url.absoluteString, docDir: docDir) else {
            task.didFailWithError(NSError(domain: "mdlive", code: 403)); return // outside doc dir / malformed
        }
        if let data = FileManager.default.contents(atPath: path) {
            let mime = Self.mime(forExtension: (path as NSString).pathExtension.lowercased())
            let resp = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
            task.didReceive(resp); task.didReceive(data); task.didFinish()
        } else {
            task.didFailWithError(NSError(domain: "mdlive", code: 404))
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    static func mime(forExtension ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
