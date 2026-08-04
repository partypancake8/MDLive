import AppKit
import SwiftUI
import Combine

/// One remappable command (id, menu title, default key + modifiers).
struct ShortcutCommand: Identifiable {
    let id: String
    let title: String
    let defaultKey: String
    let defaultMods: NSEvent.ModifierFlags
}

/// Remappable keyboard shortcuts (Shortcuts settings tab). Overrides persist to
/// UserDefaults; the main menu is rebuilt from this store, so a remap takes effect.
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    let commands: [ShortcutCommand] = [
        .init(id: "open",       title: "Open…",            defaultKey: "o", defaultMods: [.command]),
        .init(id: "refresh",    title: "Refresh",          defaultKey: "r", defaultMods: [.command]),
        .init(id: "find",       title: "Find…",            defaultKey: "f", defaultMods: [.command]),
        .init(id: "findNext",   title: "Find Next",        defaultKey: "g", defaultMods: [.command]),
        .init(id: "findPrev",   title: "Find Previous",    defaultKey: "g", defaultMods: [.command, .shift]),
        .init(id: "copyPath",   title: "Copy File Path",   defaultKey: "l", defaultMods: [.command]),
        .init(id: "reveal",     title: "Reveal in Finder", defaultKey: "r", defaultMods: [.command, .shift]),
        .init(id: "print",      title: "Print…",           defaultKey: "p", defaultMods: [.command]),
        .init(id: "zoomIn",     title: "Zoom In",          defaultKey: "=", defaultMods: [.command]),
        .init(id: "zoomOut",    title: "Zoom Out",         defaultKey: "-", defaultMods: [.command]),
        .init(id: "actualSize", title: "Actual Size",      defaultKey: "0", defaultMods: [.command]),
        .init(id: "outline",    title: "Show Outline",     defaultKey: "1", defaultMods: [.command, .option]),
        .init(id: "keepOnTop",  title: "Keep on Top",      defaultKey: "t", defaultMods: [.command, .control])
    ]

    @Published private var overrides: [String: [String: Int]] = [:] // id -> ["mods": rawValue], key stored separately
    @Published private var keyOverrides: [String: String] = [:]     // id -> key
    private let modsKey = "mdlive.shortcutMods"
    private let keysKey = "mdlive.shortcutKeys"

    private init() {
        overrides = (UserDefaults.standard.dictionary(forKey: modsKey) as? [String: Int]).map { d in d.mapValues { ["mods": $0] } } ?? [:]
        keyOverrides = (UserDefaults.standard.dictionary(forKey: keysKey) as? [String: String]) ?? [:]
    }

    private func cmd(_ id: String) -> ShortcutCommand? { commands.first { $0.id == id } }

    func key(for id: String) -> String { keyOverrides[id] ?? cmd(id)?.defaultKey ?? "" }
    func modifiers(for id: String) -> NSEvent.ModifierFlags {
        if let raw = overrides[id]?["mods"] { return NSEvent.ModifierFlags(rawValue: UInt(raw)) }
        return cmd(id)?.defaultMods ?? [.command]
    }
    func isCustom(_ id: String) -> Bool { keyOverrides[id] != nil }

    func set(_ id: String, key: String, mods: NSEvent.ModifierFlags) {
        keyOverrides[id] = key
        overrides[id] = ["mods": Int(mods.rawValue)]
        persist()
    }
    func reset(_ id: String) { keyOverrides[id] = nil; overrides[id] = nil; persist() }
    func resetAll() { keyOverrides = [:]; overrides = [:]; persist() }

    private func persist() {
        UserDefaults.standard.set(keyOverrides, forKey: keysKey)
        UserDefaults.standard.set(overrides.mapValues { $0["mods"] ?? 0 }, forKey: modsKey)
    }

    func display(for id: String) -> String { Shortcuts.glyphs(key: key(for: id), mods: modifiers(for: id)) }

    static func glyphs(key: String, mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        s += (key == "=" ? "+" : key.uppercased())   // show ⌘+ for the unshifted zoom-in accelerator
        return s
    }
}

/// Invisible NSView that captures the next key combo while recording (Shortcuts tab).
struct KeyRecorder: NSViewRepresentable {
    let onCapture: (String, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView(); v.onCapture = onCapture; v.onCancel = onCancel
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: RecorderNSView, context: Context) {
        DispatchQueue.main.async { if v.window?.firstResponder != v { v.window?.makeFirstResponder(v) } }
    }

    final class RecorderNSView: NSView {
        var onCapture: ((String, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        // Intercept modifier combos BEFORE the main menu, so a shortcut that
        // collides with an existing menu item (e.g. ⌘F) is captured, not fired.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            guard !key.isEmpty, !mods.isEmpty else { return false }
            onCapture?(key, mods)
            return true
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return } // Esc
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if key.isEmpty { return }
            onCapture?(key, mods)
        }
    }
}
