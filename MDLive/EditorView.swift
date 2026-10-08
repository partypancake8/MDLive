import SwiftUI
import AppKit

/// The three window layouts. Preview only is the default, so existing users see
/// no change until they pick another mode.
enum ViewMode: String, CaseIterable {
    case preview, split, editor
}

/// SwiftUI wrapper around the model-owned NSTextView (monospace, soft wrap,
/// native undo/redo and Cmd shortcuts). The model keeps the view alive across
/// mode switches, so undo history and the caret survive.
struct EditorView: NSViewRepresentable {
    @ObservedObject var model: PreviewModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = model.editorScrollView()
        scroll.removeFromSuperview()          // it may still be parented from the previous mode
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// How buffer text maps to bytes on disk. The editor always works with "\n";
/// saving restores the file's own line ending and trailing newline.
enum DiskText {
    static func detect(_ s: String) -> (lineEnding: String, trailingNewline: Bool) {
        let ns = s as NSString                // NSString: "\r\n" is one Character in Swift
        let crlf = ns.range(of: "\r\n").location != NSNotFound
        let trailing = s.isEmpty ? true : ns.hasSuffix("\n")
        return (crlf ? "\r\n" : "\n", trailing)
    }

    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func encode(_ text: String, lineEnding: String, trailingNewline: Bool) -> String {
        var t = normalize(text)
        if trailingNewline && !t.isEmpty && !(t as NSString).hasSuffix("\n") { t += "\n" }
        if lineEnding == "\r\n" { t = t.replacingOccurrences(of: "\n", with: "\r\n") }
        return t
    }
}
