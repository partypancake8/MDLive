import SwiftUI
import AppKit
import Combine
import Sparkle

@main
struct MDLiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Real settings live in the SwiftUI Settings scene (it owns ⌘,). Fully
        // qualified because our own `Settings` class (the store) shadows it.
        SwiftUI.Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var recentMenu = NSMenu(title: "Open Recent")
    private var shortcutsCancellable: AnyCancellable?
    // Sparkle (V21), inert: SUEnableAutomaticChecks=NO in Info.plist; only the
    // explicit "Check for Updates…" reaches the (placeholder) feed.
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["MDLIVE_SELFTEST"], let open = env["MDLIVE_OPEN"] {
            SelfTestRunner.shared.run(mdPath: open, outPath: out)
            return
        }

        buildMainMenu()
        // SwiftUI installs its OWN default main menu (only "Enter Full Screen" in View,
        // no File/Edit) and re-installs it AFTER the app becomes active and whenever a
        // window becomes key, clobbering ours. A single early reassert isn't enough
        // (it fails on a no-document launch, e.g. from Raycast/Dock). Reassert on those
        // notifications so our File/Edit/View (incl. zoom) menus always win.
        DispatchQueue.main.async { [weak self] in self?.buildMainMenu() }
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.buildMainMenu()
            }
        }
        // Rebuild the menu when a shortcut is remapped (Shortcuts settings tab).
        shortcutsCancellable = Shortcuts.shared.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.buildMainMenu() } }

        // Direct open paths (bypass Launch Services): env or argv file.
        if let p = env["MDLIVE_OPEN"], FileManager.default.fileExists(atPath: p) {
            WindowManager.shared.open(URL(fileURLWithPath: p))
        }
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") && FileManager.default.fileExists(atPath: arg) {
            WindowManager.shared.open(URL(fileURLWithPath: arg))
        }

        DispatchQueue.main.async { WindowManager.shared.showEmptyStateIfNeeded() }
    }

    // Finder / Open With / drag-on-icon (DEC-6).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { WindowManager.shared.open(url) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu (Step 8)

    private func buildMainMenu() { NSApp.mainMenu = makeMainMenu() }

    /// Build the main menu (internal so it can be exercised in tests, building it
    /// twice is the remap-rebuild path that must not crash on a re-attached submenu).
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        recentMenu = NSMenu(title: "Open Recent") // fresh each build: a submenu can't attach to two items

        // App
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MDLive", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        add(appMenu, "Check for Updates…", #selector(checkForUpdates), "")
        appMenu.addItem(.separator())
        let settingsItem = add(appMenu, "Settings…", #selector(openSettings), ",")
        _ = settingsItem
        add(appMenu, "Install Command Line Tool…", #selector(installCLI), "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MDLive", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MDLive", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        addCmd(fileMenu, "open", #selector(openDocument))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self; recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        addCmd(fileMenu, "copyPath", #selector(copyPath))
        addCmd(fileMenu, "reveal", #selector(revealInFinder))
        fileMenu.addItem(.separator())
        addCmd(fileMenu, "print", #selector(printDocument))
        add(fileMenu, "Export as PDF…", #selector(exportPDF), "")
        add(fileMenu, "Export as HTML…", #selector(exportHTML), "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // Edit (find + standard copy/select via the responder chain → WebView)
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        addCmd(editMenu, "find", #selector(findInDocument))
        addCmd(editMenu, "findNext", #selector(findNextItem))
        addCmd(editMenu, "findPrev", #selector(findPrevItem))
        editItem.submenu = editMenu

        // View
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        addCmd(viewMenu, "refresh", #selector(refreshDocument))
        viewMenu.addItem(.separator())
        addCmd(viewMenu, "actualSize", #selector(zoomReset))
        addCmd(viewMenu, "zoomIn", #selector(zoomIn))
        addCmd(viewMenu, "zoomOut", #selector(zoomOut))
        viewMenu.addItem(.separator())
        addCmd(viewMenu, "outline", #selector(toggleOutline))
        viewItem.submenu = viewMenu

        // Window
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addCmd(windowMenu, "keepOnTop", #selector(keepOnTop))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help
        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        add(helpMenu, "MDLive Help", #selector(showHelp), "")
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        return main
    }

    /// Add a remappable command: title + key + modifiers come from the Shortcuts store.
    @discardableResult
    private func addCmd(_ menu: NSMenu, _ id: String, _ action: Selector) -> NSMenuItem {
        let title = Shortcuts.shared.commands.first { $0.id == id }?.title ?? id
        let item = NSMenuItem(title: title, action: action, keyEquivalent: Shortcuts.shared.key(for: id))
        item.keyEquivalentModifierMask = Shortcuts.shared.modifiers(for: id)
        item.target = self
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openSettings() {
        // Open the SwiftUI Settings scene (macOS 14+ uses showSettingsWindow:, 13 uses showPreferencesWindow:).
        for sel in ["showSettingsWindow:", "showPreferencesWindow:"] where
            NSApp.sendAction(Selector((sel)), to: nil, from: nil) { return }
    }
    @objc private func openDocument() { EmptyStateView.openPanel() }
    @objc private func refreshDocument() { WindowManager.shared.refreshFront() }
    @objc private func revealInFinder() { WindowManager.shared.revealFront() }
    @objc private func copyPath() { WindowManager.shared.copyFrontPath() }
    @objc private func printDocument() { WindowManager.shared.printFront() }
    @objc private func exportPDF() { WindowManager.shared.exportPDFFront() }
    @objc private func exportHTML() { WindowManager.shared.exportHTMLFront() }
    @objc private func findInDocument() { WindowManager.shared.findFront() }
    @objc private func findNextItem() { WindowManager.shared.findStepFront(true) }
    @objc private func findPrevItem() { WindowManager.shared.findStepFront(false) }
    @objc private func zoomIn() { Settings.shared.fontScale = min(3.0, Settings.shared.fontScale + 0.1) }
    @objc private func zoomOut() { Settings.shared.fontScale = max(0.5, Settings.shared.fontScale - 0.1) }
    @objc private func zoomReset() { Settings.shared.fontScale = 1.0 }
    @objc private func toggleOutline() { WindowManager.shared.toggleOutlineFront() }
    @objc private func keepOnTop() { WindowManager.shared.toggleFloatFront() }
    @objc private func checkForUpdates() { updater.checkForUpdates(nil) }

    @objc private func showHelp() {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "md", subdirectory: "web") {
            WindowManager.shared.open(url)
        }
    }

    @objc private func installCLI() {
        let dir = "/usr/local/bin", path = "/usr/local/bin/mdlive"
        let script = "#!/bin/sh\nopen -a MDLive \"$@\"\n"
        var ok = false
        if FileManager.default.fileExists(atPath: dir),
           (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            ok = true
        }
        let alert = NSAlert()
        if ok {
            alert.messageText = "Command line tool installed"
            alert.informativeText = "Run:  mdlive file.md"
        } else {
            alert.messageText = "Couldn't install to /usr/local/bin"
            alert.informativeText = "That folder may not exist or need permission. Create it with:\n  sudo mkdir -p /usr/local/bin && sudo chown $(whoami) /usr/local/bin\nthen try again, or put this on your PATH:\n  #!/bin/sh\n  open -a MDLive \"$@\""
        }
        alert.runModal()
    }

    @objc private func openRecentItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { WindowManager.shared.open(url) }
    }

    // Rebuild the Open Recent submenu on demand.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = RecentFiles.urls
        if urls.isEmpty {
            let item = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
    }
}
