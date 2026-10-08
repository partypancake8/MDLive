import Foundation

/// Writes in-place edits back to the Markdown file (autosave). Pure helpers so
/// the formatting rules are unit-testable without a window.
enum DocumentSaver {
    /// Give `text` (always "\n" line breaks, from the page) the line endings and
    /// final-newline state of `original`, the text currently on disk.
    static func conform(_ text: String, to original: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
        let crlf = original.contains("\r\n")
        let wantsFinalNewline = original.unicodeScalars.last == "\n"
        if wantsFinalNewline {
            if t.unicodeScalars.last != "\n" && !t.isEmpty { t += "\n" }
        } else {
            while t.unicodeScalars.last == "\n" { t.unicodeScalars.removeLast() }
        }
        if crlf { t = t.replacingOccurrences(of: "\n", with: "\r\n") }
        return t
    }

    /// Atomic write (temp file + rename) through symlinks, keeping the file's
    /// permissions. Returns the number of bytes written.
    @discardableResult
    static func write(_ text: String, to url: URL) throws -> Int {
        let target = url.resolvingSymlinksInPath()
        let perms = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let data = Data(text.utf8)
        try data.write(to: target, options: .atomic)
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path) }
        return data.count
    }
}
