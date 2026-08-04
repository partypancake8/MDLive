import Foundation

/// Content snippet for the Recent grid's preview cards: the first lines of the
/// file (raw Markdown), bounded by line + char count. Pure → unit-testable.
enum FilePreview {
    static func snippet(for url: URL, maxLines: Int = 14, maxChars: Int = 600) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var lines = text.components(separatedBy: .newlines)
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) }
        let joined = lines.joined(separator: "\n")
        return joined.count > maxChars ? String(joined.prefix(maxChars)) : joined
    }
}
