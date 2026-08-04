# MDLive v2: Recon Doc ("normal app" feature set)

> **Phase 0 recon, not a PRD.** This investigates the current codebase and maps every requested v2 feature to *what exists / what's reusable / what's new / where it plugs in / what it depends on / what could bite*. No executable steps, no locked decisions, Open Questions (§9) stay open for S. Smith to answer before the PRD is written. The PRD will be built on the change inventory (§7) and decisions made here.

**Scope (confirmed):** Tier 1 (all) + Tier 2 (all) + Tier 3 **minus Mermaid and minus Developer-ID notarization**, plus closing MVP Steps 4 & 5. So v2 = find, settings, themes, zoom, window memory, copy-path, drag-in, outline/TOC, print/export, always-on-top, GFM completeness, scroll memory, About/Help, **LaTeX math, custom CSS, CLI helper, Sparkle auto-update, accessibility pass.**

---

## 1. Current architecture (the baseline we're extending)

Source (`MDLive/`):
- **MDLiveApp.swift**, `@main App` with a single `Settings { EmptyView() }` scene (placeholder). `AppDelegate` (NSApplicationDelegate, NSMenuDelegate): `applicationDidFinishLaunching` (self-test branch, `buildMainMenu`, env/argv open, empty-state), `application(_:open:)`, `buildMainMenu()` (App/File/View/Window menus), `@objc openDocument/refreshDocument/revealInFinder/openRecentItem`, `menuNeedsUpdate` (Recent).
- **WindowManager.swift**, `WindowManager` (one `NSWindow` per file, `docs: [URL: Doc{window,model}]`, dedupe, `open/showEmptyStateIfNeeded/refreshFront/revealFront/front/windowWillClose`), `marker()` test hook, `RecentFiles` (UserDefaults).
- **WebRenderer.swift**, `DocumentView` (ZStack: `WebRenderer` + `ErrorView`), `PreviewModel` (ObservableObject: `markdown/errorText/lastUpdated`, owns `FileWatcher`, `load/reload`), `WebRenderer` (NSViewRepresentable → WKWebView), `LinkRouter`, `ErrorView`, `EmptyStateView`.
- **WebKitRenderer.swift**, `WebKitRenderer` (WKWebView owner; `mdlive-img` scheme handler; `ready`/`link` message handlers; `loadShell/render/flush/readback`), `ImageSchemeHandler`.
- **FileWatcher.swift**, FSEvents on parent dir + 150ms debounce + (mtime,size)-stable guard + 1s poll.
- **Resources/web/**, `index.html` (`md = markdownit({...})`, `render()`, click handler, `ready` post), `theme.css`, `markdown-it.min.js`, `highlight.min.js`, `highlight-dark.css`.
- **project.yml** (XcodeGen), **Info.plist**, **scripts/build-and-sign.sh**.

**Key reuse facts that shape v2:**
- The **Swift↔JS bridge already exists** (`evaluateJavaScript` out, `WKScriptMessageHandler` in via `ready`/`link`). Most rendering-side features (themes, zoom, TOC data, math, custom CSS) extend this bridge rather than add new infra.
- **Each window is an isolated `WebKitRenderer`** with no shared config. v2 introduces app-wide **Settings** → the single biggest cross-cutting addition (§6).
- **`render()` is the one render entry point**, settings/plugins/anchors all flow through it.
- **`loadFileURL(allowingReadAccessTo: web/)`** already grants the whole `web/` dir, so new bundled assets (plugins, KaTeX, fonts) load with no extra permission work.

---

## 2. Cross-cutting backbone (build this first; every feature hangs on it)

### 2.1 Settings store + propagation  *(the linchpin)*
- **New:** a shared `Settings` (ObservableObject backed by `@AppStorage`/UserDefaults): `theme`, `fontScale`, `contentWidth`, `autoRefresh`, `pollSpeed`, `customCSSPath`, `mathEnabled`, `floatByDefault`.
- **Propagation problem:** changing a setting must reach **every open window** live. Two sinks:
  - **JS sink** (theme, fontScale, width, customCSS, math) → new JS `applySettings(opts)`; call on `ready` and whenever settings change.
  - **Swift sink** (autoRefresh on/off, pollSpeed) → `FileWatcher` must become **reconfigurable** (enable/disable; interval), today the interval (150ms debounce / 1s poll) is hard-coded.
- **Mechanism:** each `WebKitRenderer`/`PreviewModel` observes the shared `Settings` (Combine `objectWillChange`/`NotificationCenter`). Decision in §9-Q1.
- **Touches:** new `Settings.swift`; `WebKitRenderer` (apply on ready + on change); `FileWatcher` (configurable); `MDLiveApp` (Settings scene).

### 2.2 Expanded JS bridge (`index.html`)
New JS functions called from Swift: `applySettings(opts)`, `applyTheme(mode)`, `setZoom(scale)`, `scrollToAnchor(id)`, `find(query, opts)` *(if JS-based)*, `getOutline()`, `getScrollPct()`, `serializeForExport()`. New messages JS→Swift: `outline` (heading list after render), `scroll` (pct, for memory). This is additive to the existing `ready`/`link` channel.

### 2.3 Vendored assets to add (offline, pinned: provenance like PRD §7)
| Asset | For | Notes |
|-------|-----|-------|
| `markdown-it-task-lists` | GFM task lists | small |
| `markdown-it-footnote` | footnotes | small |
| `markdown-it-deflist` | definition lists | small |
| `markdown-it-anchor` | heading IDs → TOC + scrollToAnchor | needed by outline |
| **KaTeX** (js + css + **woff2 fonts**) + `markdown-it-katex` (or `katex/auto-render`) | LaTeX math | **heaviest add (~1MB fonts)**; fonts must sit under `web/` |
| **Sparkle** (SPM package) | auto-update | not a web asset; see §3 risks |

Strikethrough (`~~`) and linkify are already on in markdown-it core, verify, likely no plugin needed.

---

## 3. Per-feature recon

### TIER 1

**F1: ⌘F in-document find**
- **Approach:** WKWebView native `find(_:configuration:completionHandler:)` (macOS 13+) returns match count + highlights. No JS needed.
- **New:** a SwiftUI/AppKit **find bar** overlay on `DocumentView` (text field, match count, prev/next, close); ⌘F shows it, ⌘G / ⇧⌘G next/prev, Esc hides.
- **Touches:** `DocumentView` (overlay + focus), `WebKitRenderer` (expose `find/findNext`), `MDLiveApp` menu (Edit menu → Find ⌘F, Find Next ⌘G).
- **Risk:** there is currently **no Edit menu**, need to add one (also gives Copy/Select All explicitly). Highlight styling is system-controlled.

**F2: Settings window (⌘,)**
- **Approach:** replace `Settings { EmptyView() }` with `Settings { SettingsView() }` bound to the §2.1 store. Tabs: General (theme, font, width), Refresh (auto-refresh, poll speed), Advanced (custom CSS, math toggle).
- **Touches:** new `SettingsView.swift`, `Settings.swift`; wiring into every renderer (§2.1).

**F3: Theme: Dark / Light / System (+ light CSS)**
- **Approach:** CSS variables with `:root` dark defaults + a `[data-theme="light"]` override block (new `theme.css` section, no second file needed); "System" follows `@media (prefers-color-scheme)` by leaving the attribute unset and providing a light media block. Swift `applyTheme(mode)` sets/clears the `data-theme` attribute on `<html>`.
- **Touches:** `theme.css` (add light palette + light hljs theme, bundle `highlight` light css too), `index.html` (`applyTheme`), Settings.
- **Decision §9-Q2:** default at launch once light exists.

**F4: Text zoom (⌘+ / ⌘- / ⌘0)**
- **Approach:** `WKWebView.pageZoom` (simplest, scales whole page) **or** a CSS `--font-scale` var. Recommend `pageZoom`. Persist in Settings (`fontScale`).
- **Touches:** `WebKitRenderer` (setZoom), menu (View → zoom items), Settings.

**F5: Window frame memory**
- **Approach:** `NSWindow.setFrameAutosaveName(...)`. **Decision §9-Q3:** one shared autosave name (all doc windows reopen at last size/pos, simple) vs per-file frame in UserDefaults.
- **Touches:** `WindowManager.makeWindow/open`.

**F6: Copy file path (⌘L) + drag-file-into-window**
- **Copy path:** menu item → `NSPasteboard` with front doc URL path. Touches `WindowManager.front()`, menu.
- **Drag-in:** `.onDrop(of: [.fileURL])` on `DocumentView` (or `registerForDraggedTypes` on the host view) → `WindowManager.open`. Closes the MVP §10.1 gap (drag-onto-icon already works via `application(_:open:)`).

### TIER 2

**F7: Outline / Table of Contents**
- **Approach:** `markdown-it-anchor` adds heading IDs; after each `render()`, JS builds an outline array `(level, text, id)` and posts `outline` to Swift. **Decision §9-Q4:** render the TOC as a **native SwiftUI sidebar** (NSSplitView feel, clicking → `scrollToAnchor(id)`) vs an in-webview panel. Recommend native sidebar (toggle in View menu, ⌥⌘1).
- **Touches:** `index.html` (anchor plugin, `getOutline`, `scrollToAnchor`), `WebKitRenderer` (outline message + scroll call), `DocumentView` (sidebar), menu.
- **Risk:** anchor scroll timing right after a live re-render; re-emit outline on refresh.

**F8: Print + Export PDF / HTML**
- **Print:** `WKWebView.printOperation(with: NSPrintInfo)` (macOS 11+) → `.run()`. Menu File → Print ⌘P.
- **Export PDF:** `WKWebView.createPDF(configuration:)` → save panel.
- **Export HTML:** serialize rendered DOM + inline `theme.css` (+ used hljs/KaTeX css) into one self-contained `.html` → save. **Decision §9-Q5:** self-contained single file (recommend yes).
- **Touches:** `WebKitRenderer` (print/createPDF/serialize), new `Exporter.swift`, menu.

**F9: Always-on-top / float**
- **Approach:** per-window `NSWindow.level = .floating` toggle; optional default from Settings (`floatByDefault`). Menu Window → Keep on Top (⌃⌘T).
- **Touches:** `WindowManager` (per-window level state), menu, Settings.

**F10: GFM completeness** (task lists, footnotes, deflists, strikethrough, autolink)
- **Approach:** vendor + `md.use(...)` the plugins in `index.html`. Task-list checkboxes render disabled (preview-only). Verify strikethrough/linkify already on.
- **Touches:** `index.html`, vendored assets, `theme.css` (style checkboxes/footnotes), provenance pinning.

**F11: Scroll-position memory per file**
- **Approach:** JS reports `getScrollPct()` (on close/periodically) → Swift persists per path in UserDefaults → on open, pass stored pct as the initial `render()` scroll. Coexists with live-refresh preservation (refresh keeps current; first open restores stored).
- **Touches:** `index.html` (`getScrollPct`, accept initial pct), `WebKitRenderer`, `PreviewModel`/`WindowManager` (persist), `windowWillClose`.

**F12: About panel + Help**
- **Approach:** custom About (version, license, one-liner) via `NSApplication.orderFrontStandardAboutPanel` options or a small SwiftUI window; basic Help menu (link to README/usage).
- **Touches:** `MDLiveApp` menu, maybe `Credits.rtf` in bundle.

### TIER 3 (minus Mermaid, minus Dev-ID)

**F13: LaTeX math (KaTeX, offline)**
- **Approach:** bundle KaTeX (js+css+**woff2 fonts**) + `markdown-it-katex`/auto-render; inline `$…$`, block `$$…$$`; gate behind Settings `mathEnabled` (perf). 
- **Touches:** `web/` assets (fonts under `web/`), `index.html`, `theme.css`, Settings, provenance.
- **Risk:** **KaTeX font loading in WKWebView**, must verify fonts resolve under the `loadFileURL` read-access root; bundle size +~1MB; render cost on math-heavy docs.

**F14: Custom CSS**
- **Approach:** Settings field for a user `.css` path; Swift reads it, injects as a `<style id="user-css">` after `theme.css` via `applySettings`; reset-to-default button. **Decision §9-Q6:** also live-watch the CSS file (reuse `FileWatcher`)?
- **Touches:** Settings, `WebKitRenderer`/`index.html` (inject), optional second `FileWatcher`.
- **Note:** user's own CSS, low security risk; still load as text only.

**F15: CLI helper (`mdlive file.md`)**
- **Approach:** a 2-line wrapper script (`open -a MDLive "$@"`) installed to `/usr/local/bin/mdlive`; provide via a menu action ("Install Command Line Tool…") or document it. argv-open already supported by the app.
- **Touches:** new `scripts/mdlive`, optional installer menu item.
- **Risk:** `/usr/local/bin` may need sudo / may not be on PATH, document.

**F16: Sparkle auto-update**  ⚠ **most external dependencies**
- **Approach:** add Sparkle via SPM (`packages:` in project.yml); `SPUStandardUpdaterController`; "Check for Updates…" menu item.
- **Hard dependencies (not code):** (a) a **hosted appcast.xml + zipped releases** somewhere; (b) **EdDSA signing keys** for updates; (c) realistically **Developer-ID + notarization** so updates are trusted, which we're **skipping for now**.
- **Recommendation (§9-Q7):** wire the Sparkle *integration* (framework + menu + updater) against a **placeholder/local appcast**, but treat real auto-update as **inert until distribution (host + keys + notarization) is set up**. Don't block v2 on infra we've deferred. *This is the one Tier-3 item I'd flag as "integrate but don't expect it to actually update yet."*

**F17: Accessibility pass**
- **Approach:** WKWebView HTML is AX-accessible by default; audit the **new SwiftUI chrome** (find bar, settings, TOC sidebar, empty/error states) for `.accessibilityLabel`/traits; honor `accessibilityDisplayShouldReduceMotion`; ensure zoom (F4) serves Dynamic-Type-like scaling; VoiceOver pass.
- **Touches:** every new SwiftUI view; a checklist, not a feature.

### MVP CLEANUP (fold into v2 Phase 0)
- **Step 4**, kitchen-sink theme/element sweep + contrast; now also must cover task lists/footnotes/math/light theme.
- **Step 5**, finish `mdlive-img` **DEC-13 path validation** (canonicalize, require dir-prefix, reject traversal) + image fixtures. Currently the handler is minimal.

---

## 4. New / changed files (inventory)

| File | New? | Change |
|------|------|--------|
| `MDLive/Settings.swift` | new | shared settings store (@AppStorage) |
| `MDLive/SettingsView.swift` | new | ⌘, settings UI |
| `MDLive/FindBar.swift` | new | ⌘F find bar overlay |
| `MDLive/Outline.swift` | new | TOC sidebar + model |
| `MDLive/Exporter.swift` | new | PDF/HTML export |
| `MDLive/MDLiveApp.swift` | edit | Settings scene; Edit/View/Help menus; zoom/find/print/export/float/copy-path items |
| `MDLive/WindowManager.swift` | edit | frame autosave; float toggle; copy path; scroll persistence; pass settings to renderer |
| `MDLive/WebKitRenderer.swift` | edit | applySettings/theme/zoom/find/outline/scrollToAnchor/getScrollPct/print/createPDF/serialize |
| `MDLive/WebRenderer.swift` | edit | DocumentView: find bar + TOC sidebar + onDrop; observe Settings |
| `MDLive/FileWatcher.swift` | edit | configurable enable + interval (auto-refresh/poll-speed); optional custom-CSS watch |
| `MDLive/Resources/web/index.html` | edit | use plugins; applySettings/applyTheme/setZoom/getOutline/scrollToAnchor/getScrollPct; KaTeX; custom-css inject |
| `MDLive/Resources/web/theme.css` | edit | light palette; task-list/footnote/deflist/katex styling |
| `MDLive/Resources/web/` (assets) | new | md-it plugins, anchor, KaTeX+fonts, hljs-light |
| `project.yml` | edit | Sparkle SPM package; (new sources auto-globbed) |
| `scripts/mdlive` | new | CLI wrapper |
| `Info.plist` | edit | SUFeedURL/SUPublicEDKey (Sparkle), maybe NSPrinting |
| `MDLiveTests/` | edit | tests: settings propagation, DEC-13 path validation, outline extraction, export non-empty |

---

## 5. Reuse vs new (summary)
- **Reuse:** the JS bridge, `render()`, `loadFileURL` read-access (covers all new assets), `FileWatcher` (extend for config + custom-CSS), `WindowManager` window lifecycle, marker/self-test harness for headless verification, `RecentFiles` UserDefaults pattern (generalize into Settings).
- **New backbone:** Settings store + propagation, expanded JS bridge, Edit menu, find bar, TOC sidebar, exporter.
- **New assets:** 4 markdown-it plugins + anchor, KaTeX (+fonts), light hljs theme, Sparkle.

---

## 6. Risk register
1. **Settings → live windows propagation races** (multiple WKWebViews), pick one observation mechanism (§9-Q1); test with 2+ windows.
2. **KaTeX fonts in WKWebView**, verify woff2 under `web/` load via `loadFileURL` root; +~1MB bundle; perf-gate math.
3. **Sparkle has non-code deps** (host, EdDSA keys, ideally notarization), integrate but expect inert until distribution is solved (§9-Q7).
4. **WKWebView find** highlight styling is system-controlled; no custom highlight color.
5. **Window frame autosave** with many windows, shared name vs per-file (§9-Q3).
6. **TOC anchor scroll timing** after live re-render, re-emit outline + re-bind on every render.
7. **`pageZoom` vs CSS scale**, choose one to avoid double-scaling with content-width.
8. **Export HTML self-containment**, must inline theme + used hljs/KaTeX CSS or it renders bare.
9. **Edit menu addition**, also need to confirm default Copy/Select All still work in WKWebView (they do, but the menu wiring must not shadow them).
10. **Scroll memory vs live-refresh**, first-open restore vs refresh-preserve must not fight.

---

## 7. Suggested phase grouping (for the future PRD: NOT executable steps)
- **P0, Cleanup + backbone:** Steps 4/5; Settings store + propagation; expanded JS bridge; Edit menu. *(Unblocks everything.)*
- **P1, Reading core:** Find (F1), Themes (F3), Zoom (F4), Settings UI (F2).
- **P2, Navigation & window:** Outline/TOC (F7), frame memory (F5), scroll memory (F11), copy-path + drag-in (F6), always-on-top (F9).
- **P3, Content completeness:** GFM plugins (F10), LaTeX math (F13), custom CSS (F14).
- **P4, Output & lifecycle:** Print/Export (F8), About/Help (F12), CLI (F15), Sparkle integration (F16), accessibility pass (F17).

---

## 8. Out of scope (explicit)
- **Mermaid diagrams**, excluded per request.
- **Developer-ID signing + notarization**, deferred (ad-hoc local signing only). Note this **partially blocks Sparkle** (F16) from being a real updater.
- Editing, vaults, sync, collaboration, App Store/sandbox (unchanged from PRD §6/§0-OUT).

---

## 9. Open questions (decide before writing the PRD)
- **Q1, Settings propagation mechanism:** shared `Settings` ObservableObject observed by each renderer, or NotificationCenter broadcast? *(Recommend: shared ObservableObject + Combine.)*
- **Q2, Default theme once light exists:** launch dark always, or follow System? *(Recommend: follow System, dark fallback.)*
- **Q3, Window frame memory:** one shared last-frame for all windows, or per-file? *(Recommend: shared, simplest; per-file later.)*
- **Q4, TOC presentation:** native SwiftUI sidebar vs in-webview panel? *(Recommend: native sidebar.)*
- **Q5, Export HTML:** self-contained single file (inline CSS/JS)? *(Recommend: yes.)*
- **Q6, Custom CSS:** also live-watch the CSS file? *(Recommend: yes, reuse FileWatcher.)*
- **Q7, Sparkle:** integrate now against a placeholder appcast (inert until host+keys+notarization), or defer the whole item until distribution is set up? *(Recommend: integrate the plumbing, keep it inert, document the host/keys/notarization prerequisites.)*
- **Q8, Zoom mechanism:** `pageZoom` vs CSS font-scale? *(Recommend: `pageZoom`.)*
- **Q9, CLI install:** in-app "Install Command Line Tool…" action vs documented manual step? *(Recommend: in-app action.)*
