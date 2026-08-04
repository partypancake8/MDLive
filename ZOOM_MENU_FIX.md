# Fix: Zoom / custom menu not working

**Date:** 2026-07-21

## Symptom
Zoom (⌘+ / ⌘- / ⌘0) did nothing. The **View** menu showed only "Enter Full Screen";
the menu bar was just `MDLive / View / Window / Help` — no File or Edit menu.

## Root cause
`MDLiveApp` is a SwiftUI `App` (with a `Settings` scene) using an `AppDelegate`.
The delegate built the full AppKit menu (File/Edit/View-with-zoom) and set
`NSApp.mainMenu` in `applicationDidFinishLaunching`. **SwiftUI installs its own
default main menu *after* `didFinishLaunching` returns**, clobbering the custom one.
Only SwiftUI's default View menu ("Enter Full Screen") survived, so the zoom items
never existed to click. The zoom *action* chain itself was fine
(`fontScale` → `Settings.objectWillChange` → `applyCurrentSettings` → `webView.pageZoom`;
verified: pageZoom 2.5 shrinks `window.innerWidth` 1728→691).

A secondary keyboard issue: Zoom In's key equivalent was the shifted symbol `"+"`
with a command-only modifier mask, which matches unreliably.

## Fix (2 files)
- **`MDLive/MDLiveApp.swift`** — reassert the custom menu whenever SwiftUI would
  re-install its own. A single early reassert is NOT enough: SwiftUI re-installs its
  stub menu *after the app becomes active* and *whenever a window becomes key*. Crucially
  this only broke the **no-document launch** (Raycast/Dock/Spotlight — app opened with no
  file); launching with a file argument happened to dodge it, which is why terminal tests
  (always run with a file) all passed. Fix reasserts on both notifications:
  ```swift
  buildMainMenu()
  DispatchQueue.main.async { [weak self] in self?.buildMainMenu() }
  for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          self?.buildMainMenu()
      }
  }
  ```
- **`MDLive/Shortcuts.swift`** — bind Zoom In to the unshifted `"="` key (reliable),
  and display it as `⌘+` via a glyph alias so the menu looks unchanged.

## How it was diagnosed
The menu is app-wide, so different windows behaving differently = different processes.
Verified the real state by logging `NSApp.mainMenu` titles to a file 1.5s after launch,
launched both with a file (full menu ✓) and via bundle id with no file (stub menu ✗) —
which isolated the no-document launch as the trigger.

## Note on "it worked in one window but not another"
That was two MDLive **processes** from different binaries (a fixed build + a stale
copy). The menu is app-wide, so mismatched windows = different processes. There were
4 copies on disk (`/Applications`, `build/dd` Debug/Release, plus dev builds); all
were rebuilt from the fixed source and re-registered with LaunchServices.
Quit all MDLive windows before relaunching to avoid running a stale instance.
