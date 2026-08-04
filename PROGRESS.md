# MDLive — Build Progress (Ralph-loop memory)

Source of truth for *what* to build: `PRD.md`. This file tracks *where the build is*.

**Status (EOD 2026-06-23):** PRD locked v2. App builds clean (Xcode 26, Swift 5 mode, unsigned), **installed at `/Applications/MDLive.app`**. hello.md renders correctly in the real WKWebView (headless self-test + live GUI window). Window-spawn bug fixed. **App icon added** (`Resources/MDLive.icns`, dark M⌄ mark). `README.md` written (day-1 summary). Launch: `open -a MDLive sample/hello.md`. **Next: Step 6 (live file watching) — not yet built; app loads once on open.**

## Step status
| Step | Title | Status | Notes |
|------|-------|--------|-------|
| 0 | Toolchain + skeleton | ✅ done | xcodegen + project.yml; builds; runs |
| 1 | Doc type registration | ✅ done | `net.daringfireball.markdown` confirmed in built Info.plist |
| 2 | Window-per-file + Finder open | 🟡 partial | AppKit WindowManager: open/dedupe/Finder-open done; ⌘O via empty-state button; full menus = Step 8 |
| 3 | Static render pipeline | ✅ done | markdown-it 14.1.0 + highlight.js 11.10.0 offline; `render()` authored; self-test gate green |
| 4 | Dark theme + element coverage | 🟡 partial | theme.css written per §5.6; kitchen-sink.md + element checklist still TODO |
| 5 | Relative images + link routing | 🟡 partial | LinkRouter routes web/`.md`(new window)/local; `mdlive-img` handler is minimal (no DEC-13 path validation yet); image fixtures TODO |
| 6 | Live watching + incremental refresh | ✅ done | FSEvents+debounce+stable-guard; XCTest green; e2e: external write + atomic replace both re-render |
| 7 | Polling fallback + robustness | ✅ done | e2e: 50-write burst → 2 renders, no crash; delete survives; recreate recovers |
| 8 | Manual refresh + menus | ✅ built | AppKit main menu (Open/Open Recent/Reveal/Close/Refresh ⌘R); builds + launches clean. Menu *clicks* not headlessly testable (AX denied) — refresh uses same reload() path verified elsewhere |
| 9 | Empty + error states | ✅ done | §5.5 exact strings; error overlay; delete→error path exercised without crash |
| 10 | Multi-window isolation | ✅ done | e2e: editing 1 of 2 windows re-renders only that one; XCTest proves model+watcher deallocate on release (teardown) |
| 11 | Sign + notarize | ✅ local tier | ad-hoc signed Release installed + verified (codesign valid). Ship tier (Developer-ID notarize) scripted in scripts/build-and-sign.sh, gated on Apple Developer ID |
| 12 | Daily-driver stress pass | 🟡 covered | core stress (burst/atomic/delete/recreate/2-window) verified above; full §20 sweep optional |

## Decisions log
- DEC-1..DEC-13 in PRD §1.
- **DEC-6 amended during build:** SwiftUI `WindowGroup(for: URL.self)` → AppKit `WindowManager`. Reason: value-scene state restoration + onAppear/onReceive drain race loop-spawned windows and resurrected a stale window (verified). AppKit = deterministic one-window-per-file + clean teardown.

## Verification artifacts (this build)
- Headless render gate: `MDLIVE_SELFTEST` readback shows `<h1>Hello, MDLive</h1>`, `<strong>`, inline `<code>`, `hljs-keyword` (syntax highlight), `<blockquote>`. exit 0.
- GUI window gate (`MDLIVE_GUI_MARKER`): open hello.md → `open ... total=1` + `rendered 232 chars`; re-open → `focus ... total=1` (deduped). Zero ghost windows.

## v2 build (PRD-v2.md) — in progress 2026-06-24
| Step | Status | Verify |
|------|--------|--------|
| V0 vendor assets + Sparkle | ✅ | assets pinned (sha256), globals confirmed, KaTeX+fonts via npm pack, Sparkle SPM linked, build clean |
| V1 Settings store + window | ✅ | SettingsTests green; ⌘, window (WindowManager.showSettings) |
| V2 settings propagation | ✅ | self-test: theme=light + contentMax=1100px applied to live doc |
| V3 FileWatcher configurable | ✅ | testDisabledWatcherEmitsNothing green; 4 v1 watcher tests still green |
| V4 image path validation (DEC-13) | ✅ | ImageResolverTests (4) green; with-image.md → mdlive-img src + 2 links tagged |
| V5 theme/element sweep | ✅ | kitchen-sink.md: all 13 element types present |
| V6 dark+light themes | ✅ (visual manual) | theme.css refactored to CSS vars + [data-theme=light] + light hljs; attr toggles (V2) |
| V9 content width | ✅ | --content-max var via applySettings (verified V2) |
| V7 zoom | ✅ build + logic | ⌘+/-/0 → Settings.fontScale → pageZoom (clamp 0.5–3.0). Visual manual |
| V8 find | ✅ build | JS find (DEC-V13) + FindBar + Edit menu + count; GUI manual |
| V10 outline/TOC | ✅ | anchor ids; getOutline; outlineLen=3 for kitchen-sink; sidebar ⌥⌘1; GUI manual |
| V11 frame memory | ✅ build | setFrameAutosaveName + clamp; GUI manual |
| V12 scroll memory | ✅ | ScrollMemory round-trip test green; first-render restore (JS); GUI manual |
| V13 copy-path + drag-in | ✅ build | ⌘L pasteboard; onDrop .fileURL; GUI manual |
| V14 always-on-top | ✅ build | ⌃⌘T window.level; floatByDefault; GUI manual |
| V15 GFM styling | ✅ | plugins loaded V5; task/footnote/deflist styled; in kitchen-sink readback |
| V16 math (KaTeX) | ✅ | auto-render gated by mathEnabled; .katex present when on; off=raw |
| V17 custom CSS | ✅ | self-test: injected userCSS; live-watch via cssWatcher |
| V18 print/export | ✅ build | Exporter (printOperation/createPDF/serializeForExport); GUI manual |
| V19 about/help | ✅ build | standard About (version); Help opens bundled Help.md in MDLive |
| V20 CLI installer | ✅ build | writes /usr/local/bin/mdlive; alert on failure; GUI manual |
| V21 Sparkle (inert) | ✅ build | SPM linked; Check for Updates menu; SUEnableAutomaticChecks=NO |
| V22 a11y | 🟡 partial | accessibilityLabels on FindBar/Outline/Error; VoiceOver pass = manual |

## Shortcuts tab (add-on, user-requested 2026-06-24) + full test pass
- Remappable keyboard shortcuts (Shortcuts settings tab, key recorder, per-row reset) + **Restore Defaults** (resets all settings + shortcuts).
- **Bug found + fixed:** remap crashed (SIGABRT) — the shared `recentMenu` (Open Recent) was re-attached on menu rebuild (an NSMenu can't be a submenu of two items). Fix: fresh recent submenu per build. **Caught by new `MenuRebuildTests`.**
- Recorder intercepts colliding combos via `performKeyEquivalent` (so recording ⌘F captures, not fires Find).

**Test coverage — 28 XCTests green** (was 14): FileWatcher×5, ImageResolver×4, Settings×7 (persist/jsOpts/poll/contentMax/scroll/restoreDefaults), Shortcuts×5 (default/remap/reset/resetAll/decodeFind/glyphs), **MenuRebuild×1** (build-twice remap, the crash repro), **Recorder×4** (performKeyEquivalent capture, bare-key ignore, Esc, full capture→set→menu chain), **LinkRouter×4** (classify web/.md/other). Plus real-WebView self-test now also probes **find JS** (40 matches on kitchen-sink) + **serializeForExport** (HTML w/ style+h1). Refactors for testability: `LinkRouter.classify` (pure), `WebKitRenderer.decodeFind` (internal), `AppDelegate.makeMainMenu()` (returns the menu).
**Still GUI-only (inherent — no screen-rec/AX):** visual layout of find bar/sidebar/settings, NSSavePanel dialogs, VoiceOver. The logic behind each is unit-tested.

**Verified (XCTest, 14 green):** watcher×5, image×4, settings/scroll×5. **Self-test/marker green:** render, theme+width propagation, image rewrite, kitchen-sink 13 elements, outline, math, custom-CSS, live-refresh (normal+atomic), window isolation+teardown. **Build:** clean (Sparkle SPM linked). **Manual-visual remaining (macOS denies screen-rec/AX to this process):** menus firing, find bar UI, outline sidebar, zoom/theme visuals, print/export dialogs, CLI install, VoiceOver.

**Decisions recorded mid-build:** DEC-V10 amended — math via **KaTeX auto-render** (post-render), not a md-it plugin (the @vscode plugin's dist path was broken; auto-render is the standard browser path). Settings uses **@Published+UserDefaults** (not raw @AppStorage) so objectWillChange fires for the Combine observers DEC-V2 needs. Test stack: 13 XCTests green (5 watcher + 4 settings + 4 image).

## Next pass resumes at
**Steps 6–11 complete & verified (2026-06-24).** MDLive now live-refreshes on external edits — the core product works. Remaining polish: Step 4 (kitchen-sink theme/element pass), Step 5 (mdlive-img DEC-13 path validation + image fixtures), and Step 11 ship tier (Developer-ID notarization — needs Apple Developer ID). Test instrumentation (`MDLIVE_GUI_MARKER` render/window/deinit markers) is env-gated and left in for future headless verification.
