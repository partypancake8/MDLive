import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings UI (⌘,). Grouped Forms for the native macOS look; a Shortcuts tab to
/// view/remap keybinds; a Restore Defaults button (resets all settings + shortcuts).
struct SettingsView: View {
    @ObservedObject private var s = Settings.shared

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            refresh.tabItem { Label("Refresh", systemImage: "arrow.clockwise") }
            advanced.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 540, height: 400)
    }

    private var general: some View {
        Form {
            Picker("Theme", selection: $s.theme) {
                Text("Dark").tag("dark"); Text("Light").tag("light")
            }
            Picker("Content width", selection: $s.contentWidth) {
                Text("Narrow").tag("narrow"); Text("Medium").tag("medium")
                Text("Wide").tag("wide"); Text("Full").tag("full")
            }
            LabeledContent("Font scale") {
                HStack(spacing: 10) {
                    Slider(value: $s.fontScale, in: 0.5...3.0, step: 0.1)
                    Text(String(format: "%.1f×", s.fontScale)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            RestoreDefaultsRow()
        }
        .formStyle(.grouped)
    }

    private var refresh: some View {
        Form {
            Toggle("Auto-refresh when the file changes", isOn: $s.autoRefresh)
            Picker("Polling speed", selection: $s.pollSpeed) {
                Text("Fast (0.5s)").tag("fast"); Text("Normal (1s)").tag("normal"); Text("Low power (3s)").tag("lowPower")
            }
            Toggle("New windows stay on top", isOn: $s.floatByDefault)
            RestoreDefaultsRow()
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Toggle("Render LaTeX math (KaTeX)", isOn: $s.mathEnabled)
            LabeledContent("Custom CSS") {
                HStack(spacing: 8) {
                    Text(s.customCSSPath.isEmpty ? "None" : (s.customCSSPath as NSString).lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { pickCSS() }
                    Button("Reset") { s.customCSSPath = "" }.disabled(s.customCSSPath.isEmpty)
                }
            }
            RestoreDefaultsRow()
        }
        .formStyle(.grouped)
    }

    private func pickCSS() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "css")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { s.customCSSPath = url.path }
    }
}

/// Shared "Restore Defaults" row — resets every setting tab + shortcuts.
struct RestoreDefaultsRow: View {
    @State private var confirming = false
    var body: some View {
        Section {
            HStack {
                Spacer()
                Button("Restore Defaults") { confirming = true }
                    .confirmationDialog("Restore all settings and shortcuts to defaults?",
                                        isPresented: $confirming, titleVisibility: .visible) {
                        Button("Restore Defaults", role: .destructive) {
                            Settings.shared.restoreDefaults(); Shortcuts.shared.resetAll()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        }
    }
}

/// Shortcuts tab — lists every app shortcut; click Record to remap (Esc cancels).
struct ShortcutsTab: View {
    @ObservedObject private var shortcuts = Shortcuts.shared
    @State private var recordingID: String? = nil

    var body: some View {
        Form {
            ForEach(shortcuts.commands) { c in
                LabeledContent(c.title) {
                    HStack(spacing: 8) {
                        if recordingID == c.id {
                            Text("Type a shortcut…").foregroundStyle(.secondary)
                            KeyRecorder(onCapture: { key, mods in
                                shortcuts.set(c.id, key: key, mods: mods); recordingID = nil
                            }, onCancel: { recordingID = nil })
                            .frame(width: 0, height: 0)
                        } else {
                            Text(shortcuts.display(for: c.id))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(shortcuts.isCustom(c.id) ? Color.accentColor : .primary)
                        }
                        Spacer()
                        Button(recordingID == c.id ? "Cancel" : "Record") {
                            recordingID = (recordingID == c.id) ? nil : c.id
                        }
                        Button("Reset") { shortcuts.reset(c.id) }.disabled(!shortcuts.isCustom(c.id))
                    }
                }
            }
            RestoreDefaultsRow()
        }
        .formStyle(.grouped)
    }
}
