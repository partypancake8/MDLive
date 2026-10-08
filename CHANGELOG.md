# MDLive: Changelog / Work Log

## 2026-10-08
- **Took out the editor pane.** Reverted e15073e, 4be3ac7 and fb5d499 (raw text editor pane, the three layouts on ⌘1/⌘2/⌘3, New / Save As / Revert, the autosave toggle and the Editing settings tab). Menus, shortcuts and settings are exactly what they were at d10a7b8.
- **Edit in place instead.** Click anywhere in the rendered document and type. `index.html` gains `enableEditing()`, which the Mac app calls after `ready`; it makes `#content` contenteditable with the same CSS, theme and fonts (only the focus outline is hidden). The Linux port never calls it and stays a read-only preview. KaTeX math, Mermaid diagrams and footnote references are `contenteditable=false` atoms whose Markdown comes from their stored source; code blocks are plain editable text and keep their fence and language; Enter inside a code block adds a line, inside a table cell does nothing; paste is plain text.
- **Block splicing, not re-serialisation.** A markdown-it core rule stamps every top-level block with `data-src-start`/`data-src-end` from `token.map`. On input, only the blocks whose DOM changed are converted back to Markdown and spliced into the original text at their line ranges. Inside a changed block a three-way line merge (original source, pristine block, edited block) keeps the original bytes of every line the edit did not touch, so table padding, list markers and `[^1]:` labels survive. The DOM to Markdown converter is a small one in `web/edit.js` for exactly the elements markdown-it produces, so nothing new was vendored (Turndown not needed). `web/edit.js` sha256 `1caae94c…40a54ec2` at this commit.
- **Autosave.** The page posts the full new Markdown to a native `edit` handler only on a real content change (opening, clicking, moving the caret or selecting never writes). `PreviewModel` debounces 1 s and writes atomically through symlinks, keeping permissions, CRLF line endings and the final newline state. `FileWatcher.noteSelfWrite()` plus a content check stop the app's own write from re-rendering under the caret; an outside change that lands while an edit is pending loses to the save. Pending edits are flushed when the window closes or the app quits.
- **Tests.** Headless edit gate `MDLIVE_EDIT_SELFTEST` (+ `MDLIVE_OPEN`, optional `MDLIVE_EDIT_TEXT`, `MDLIVE_EDIT_SELECTOR`). `web-tests/edit-test.sh` (9 checks: paragraph, list item, task item, code line, table cell, heading, footnote, Enter, no-op). `EditingTests` (10 XCTests: debounce, atomic write, symlink + permissions, CRLF and final newline, self-write suppression, pending save wins). 42 XCTests green. Version 0.2.0.

## 2026-09-22
- **Mermaid sizing (standard practice):** diagrams are no longer scaled down to fit the column. Mermaid is initialised with `useMaxWidth: false` for every diagram type (the Mermaid Live Editor / docs practice) so each SVG keeps its natural pixel size and 16px text (`themeVariables.fontSize`, sequence message/actor 16px, notes 14px, page font family); the host is `overflow-x: auto; max-width: 100%`, so a wide diagram scrolls sideways like a wide table. A "Fit width" button appears only above diagrams wider than the column and toggles viewBox scaling. Page zoom (⌘+/-) still scales diagrams with the text; theme toggles re-render with the same config. Readback gains `mermaidMetrics` (svg size, host width, text font size, toggle) and `web-tests/mermaid-test.sh` grows to 13 checks including a wide 11-participant sequence in `sample/mermaid.md`.
- **Mermaid diagrams, offline:** fenced ` ```mermaid ` blocks render to SVG via a vendored Mermaid 11.17.2 (`web/mermaid.min.js`, sha256 `581ed7d7…90eb8`), initialised once with `startOnLoad: false` and `securityLevel: 'strict'`; highlight.js skips them. The Mermaid theme follows Dark/Light and a theme toggle re-renders every diagram from its stored source. A diagram that fails to parse keeps its fenced source with a one-line `Mermaid error:` notice above it. New `sample/mermaid.md`, `web-tests/mermaid-test.sh` (headless WKWebView via `MDLIVE_SELFTEST`, 6 checks), readback gains `mermaidSvg`/`mermaidErrors`, self-test waits for async rendering. 32 XCTests green.

## 2026-06-25
- **Recent Files on the home screen:** `EmptyStateView` gains a "Recent" grid (thumbnail + filename, click-to-open) below the Open button, shown when recents exist. Thumbnails via `QLThumbnailGenerator` with an instant `NSWorkspace` file-icon fallback; moved/deleted files filtered out (`RecentFiles.existing`). Tests: `computeList` (dedupe/order/cap), `.existing` filter, `fileIcon`, 31 XCTests green.
- Distribution still blocked on Apple Developer Program activation (enrolled 06-24; account not yet showing paid locally, only a free Personal Team + Apple Development cert). Ad-hoc share build at `/Users/Shared/MDLive.zip`.

## 2026-06-24: v2 "normal-app" feature set + polish

### Planning (PRD-first)
- **`RECON-v2.md`**, Phase-0 recon of what a normal native viewer still needs, grounded in the v1 code; tiers + open questions.
- **`PRD-v2.md`**, written, then reworked to actually follow the Decypher `prd-template.md` (added **Key terms for the executing agent**, Execution protocol, Source-requirements-verbatim, Current-state/Inherited-state, per-step Objective/Files/Tests-first/Implementation/Gate/Failure blocks, Risks/Security/Rollback/Cutover, Contents, How-to-read).
- **PB&J adversarial pass** (fresh zero-context agent vs the real code) → found 2 blockers + ~10 gaps (missing §3.1 keys table, un-wired Settings→renderer, native-find-has-no-count, `flush`/`render` symbol drift, V11 autosave vs `center()`, etc.) → all fixed → **Status LOCKED**.

### Built: all 22 steps (V0-V22)
- **Backbone:** shared `Settings` store (`@Published`+UserDefaults singleton) + live propagation to every window (Combine); `FileWatcher` made configurable (auto-refresh on/off, poll speed).
- **Reading:** Dark + **Light** themes (CSS-variable refactor + `[data-theme=light]`), **zoom** (⌘+/-/0 via `pageZoom`), content width, **⌘F find** with match count (JS highlighter, native `WKWebView.find` has no count).
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

### Tests: 28 XCTests green (was 14) + real-WebView self-test
- New: `RecorderTests` (synthetic-NSEvent capture, the gap that crashed), `MenuRebuildTests` (build-twice remap repro), `LinkRouterTests` (pure `classify`), Settings `restoreDefaults`, Shortcuts `resetAll`/`decodeFind`, image-path-validation.
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
- **Git:** repo initialized locally (`main` branch, v1 baseline staged). `git commit` hangs in this sandbox (commit via `!` in the user's shell). **Not pushed**, `partypancake8/MDLive` (personal account) isn't reachable from the work-account `gh` login; will not push to the work account.
- Earlier backup: `/Volumes/diskdisk/MDLive-backup-2026-06-24.zip` (now stale vs v2).

## 2026-06-23: v1 MVP (prior session)
Render + live file watching (FSEvents + debounce + atomic-replace handling) + multi-window + menus + error/empty states + dark theme + app icon; ad-hoc signed. See `PRD.md` (v1, Steps 0-11) and `PROGRESS.md`.
