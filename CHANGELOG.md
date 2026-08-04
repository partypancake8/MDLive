# MDLive — Changelog / Work Log

## 2026-06-25
- **Recent Files on the home screen:** `EmptyStateView` gains a "Recent" grid (thumbnail + filename, click-to-open) below the Open button, shown when recents exist. Thumbnails via `QLThumbnailGenerator` with an instant `NSWorkspace` file-icon fallback; moved/deleted files filtered out (`RecentFiles.existing`). Tests: `computeList` (dedupe/order/cap), `.existing` filter, `fileIcon` — 31 XCTests green.
- Distribution still blocked on Apple Developer Program activation (enrolled 06-24; account not yet showing paid locally — only a free Personal Team + Apple Development cert). Ad-hoc share build at `/Users/Shared/MDLive.zip`.

## 2026-06-24 — v2 "normal-app" feature set + polish

### Planning (PRD-first)
- **`RECON-v2.md`** — Phase-0 recon of what a normal native viewer still needs, grounded in the v1 code; tiers + open questions.
- **`PRD-v2.md`** — written, then reworked to actually follow the Decypher `prd-template.md` (added **Key terms for the executing agent**, Execution protocol, Source-requirements-verbatim, Current-state/Inherited-state, per-step Objective/Files/Tests-first/Implementation/Gate/Failure blocks, Risks/Security/Rollback/Cutover, Contents, How-to-read).
- **PB&J adversarial pass** (fresh zero-context agent vs the real code) → found 2 blockers + ~10 gaps (missing §3.1 keys table, un-wired Settings→renderer, native-find-has-no-count, `flush`/`render` symbol drift, V11 autosave vs `center()`, etc.) → all fixed → **Status LOCKED**.

### Built — all 22 steps (V0–V22)
- **Backbone:** shared `Settings` store (`@Published`+UserDefaults singleton) + live propagation to every window (Combine); `FileWatcher` made configurable (auto-refresh on/off, poll speed).
- **Reading:** Dark + **Light** themes (CSS-variable refactor + `[data-theme=light]`), **zoom** (⌘+/-/0 via `pageZoom`), content width, **⌘F find** with match count (JS highlighter — native `WKWebView.find` has no count).
- **Navigation/window:** **outline/TOC sidebar** (⌥⌘1), window-frame memory, per-file scroll memory, **⌘L copy path** + drag-to-open, **⌃⌘T always-on-top**.
- **Content:** GFM **task lists / footnotes / definition lists / strikethrough** (markdown-it plugins, vendored); **LaTeX math** via **KaTeX auto-render** (offline, toggle); **custom CSS** (live-watched).
- **Output/lifecycle:** **print + export PDF/HTML** (`serializeForExport` inlines CSS), About + Help (opens bundled `Help.md` in MDLive), **CLI installer** (`/usr/local/bin/mdlive`), **Sparkle** auto-update plumbing (inert: `SUEnableAutomaticChecks=NO`, placeholder feed), accessibility labels.
- **Cleanup:** `mdlive-img` **path validation (DEC-13)** + image fixtures; kitchen-sink theme/element sweep.
- **Assets vendored & pinned** (SHA-256): markdown-it task-lists/footnote/deflist/anchor, KaTeX 0.16.11 (+20 woff2 fonts via `npm pack`), github light hljs; Sparkle via SPM.

### Shortcuts (user-requested add-on)
- **Shortcuts settings tab:** lists every app shortcut, **remap via a key recorder** (Esc cancels; intercepts colliding combos via `performKeyEquivalent`), per-row reset, glyph display.
- **Restore Defaults** button (resets all settings + all shortcuts).
- Menu now reads keys from the `Shortcuts` store and rebuilds on remap.

### Bugs fixed
- **Remap crash (SIGABRT):** rebuilding the menu re-attached the shared `recentMenu` (an `NSMenu` can't be a submenu of two items). Fix: fresh recent submenu per build. Caught by new `MenuRebuildTests`.
- **Empty Settings window:** SwiftUI's placeholder `Settings { EmptyView() }` scene was intercepting ⌘,. Fix: moved `SettingsView` into the Settings scene.
- **Settings formatting:** switched to `.formStyle(.grouped)` + `LabeledContent` for the native macOS look.

### Tests — 28 XCTests green (was 14) + real-WebView self-test
- New: `RecorderTests` (synthetic-NSEvent capture — the gap that crashed), `MenuRebuildTests` (build-twice remap repro), `LinkRouterTests` (pure `classify`), Settings `restoreDefaults`, Shortcuts `resetAll`/`decodeFind`, image-path-validation.
- Self-test harness extended to probe **find JS** (count) + **serializeForExport** in the real WKWebView.
- Refactors for testability: `LinkRouter.classify`, `WebKitRenderer.decodeFind`, `AppDelegate.makeMainMenu()`.
- **Irreducible gap:** visual GUI (find-bar/sidebar/settings layout, save dialogs, VoiceOver) can't be driven headlessly here (macOS denies screen-recording/Accessibility); the logic behind each is unit-tested.

### Icon
- Removed the inner border square; **centered the M + down-arrow** group; widened the M↔arrow gap. Regenerated `MDLive.icns` (1024 master → iconset → icns).

### Distribution (investigated, not done)
- Downloadable + clean-open requires **Apple Developer ID ($99/yr)** → notarized `.dmg` on GitHub Releases. Local check: only a **free "Personal Team"** (`9H66KDLNGH`), which **can't notarize**. Options: enroll (paid) for a notarized DMG, or ship an **unsigned DMG** (right-click→Open). `scripts/build-and-sign.sh ship` is ready for the notarized path.

### Ops / housekeeping
- App built **Release, ad-hoc signed, installed to `/Applications`** throughout.
- **Raycast icon not updating** → stale IconServices/Raycast cache; fixed via `lsregister -f` + restart icon agent/Dock/Raycast (deep reset = `sudo rm -rf /Library/Caches/com.apple.iconservices.store`).
- **Git:** repo initialized locally (`main` branch, v1 baseline staged). `git commit` hangs in this sandbox (commit via `!` in the user's shell). **Not pushed** — `partypancake8/MDLive` (personal account) isn't reachable from the work-account `gh` login; will not push to the work account.
- Earlier backup: `/Volumes/diskdisk/MDLive-backup-2026-06-24.zip` (now stale vs v2).

## 2026-06-23 — v1 MVP (prior session)
Render + live file watching (FSEvents + debounce + atomic-replace handling) + multi-window + menus + error/empty states + dark theme + app icon; ad-hoc signed. See `PRD.md` (v1, Steps 0–11) and `PROGRESS.md`.
