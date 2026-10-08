import SwiftUI
import Combine

/// App-wide settings (PRD §3.1). Singleton referenced directly by every consumer
/// (DEC-V14, AppKit document windows can't receive the SwiftUI `Settings` scene
/// environment). Backed by `@Published` + UserDefaults rather than `@AppStorage`
/// so `objectWillChange` fires for the non-SwiftUI Combine observers (each
/// WebKitRenderer) that DEC-V2 relies on.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var theme: String { didSet { d.set(theme, forKey: "mdlive.theme") } }            // "dark"|"light"
    @Published var fontScale: Double { didSet { d.set(fontScale, forKey: "mdlive.fontScale") } } // 0.5...3.0
    @Published var contentWidth: String { didSet { d.set(contentWidth, forKey: "mdlive.contentWidth") } }
    @Published var autoRefresh: Bool { didSet { d.set(autoRefresh, forKey: "mdlive.autoRefresh") } }
    @Published var pollSpeed: String { didSet { d.set(pollSpeed, forKey: "mdlive.pollSpeed") } } // fast|normal|lowPower
    @Published var customCSSPath: String { didSet { d.set(customCSSPath, forKey: "mdlive.customCSSPath") } }
    @Published var mathEnabled: Bool { didSet { d.set(mathEnabled, forKey: "mdlive.mathEnabled") } }
    @Published var floatByDefault: Bool { didSet { d.set(floatByDefault, forKey: "mdlive.floatByDefault") } }

    private init() {
        theme = d.string(forKey: "mdlive.theme") ?? "dark"
        fontScale = (d.object(forKey: "mdlive.fontScale") as? Double) ?? 1.0
        contentWidth = d.string(forKey: "mdlive.contentWidth") ?? "medium"
        autoRefresh = (d.object(forKey: "mdlive.autoRefresh") as? Bool) ?? true
        pollSpeed = d.string(forKey: "mdlive.pollSpeed") ?? "normal"
        customCSSPath = d.string(forKey: "mdlive.customCSSPath") ?? ""
        mathEnabled = (d.object(forKey: "mdlive.mathEnabled") as? Bool) ?? false
        floatByDefault = (d.object(forKey: "mdlive.floatByDefault") as? Bool) ?? false
    }

    // Derived mappings
    var pollInterval: TimeInterval {
        switch pollSpeed { case "fast": return 0.5; case "lowPower": return 3.0; default: return 1.0 }
    }
    var contentMaxCSS: String {
        switch contentWidth {
        case "narrow": return "640px"; case "wide": return "1100px"; case "full": return "100%"; default: return "860px"
        }
    }
    func clampFontScale() { fontScale = min(3.0, max(0.5, fontScale)) }

    /// Reset every setting to its default (the "Restore Defaults" button).
    func restoreDefaults() {
        theme = "dark"; fontScale = 1.0; contentWidth = "medium"
        autoRefresh = true; pollSpeed = "normal"
        customCSSPath = ""; mathEnabled = false; floatByDefault = false
    }

    /// The opts payload handed to JS `applySettings` (§3.2). Pure → unit-testable.
    func jsOptsJSON(customCSS: String) -> String {
        let obj: [String: Any] = [
            "theme": theme,
            "contentWidth": contentWidth,
            "contentMax": contentMaxCSS,
            "mathEnabled": mathEnabled,
            "customCSS": customCSS
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
