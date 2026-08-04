import AppKit
import WebKit
import UniformTypeIdentifiers

/// Print + export (V18). PDF uses the live WebView (fully self-contained, incl.
/// images + fonts). HTML inlines the stylesheets via `serializeForExport()`.
enum Exporter {
    static func printDoc(_ webView: WKWebView) {
        let op = webView.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = webView.bounds
        op.run()
    }

    static func exportPDF(_ webView: WKWebView) {
        webView.createPDF { result in
            if case .success(let data) = result { save(data, suggested: "export.pdf", type: .pdf) }
        }
    }

    static func exportHTML(_ webView: WKWebView) {
        webView.evaluateJavaScript("serializeForExport()") { value, _ in
            if let html = value as? String, let data = html.data(using: .utf8) {
                save(data, suggested: "export.html", type: .html)
            }
        }
    }

    private static func save(_ data: Data, suggested: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggested
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}
