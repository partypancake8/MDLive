# MDLive

A tiny native macOS app that previews Markdown and live-refreshes when the file
changes on disk — built for working alongside AI coding agents (Claude Code,
Codex) that edit `.md` files externally. Preview-only: no editor, no vault, no
server. See [`PRD.md`](PRD.md) for the full spec and [`PROGRESS.md`](PROGRESS.md)
for step-by-step status.

## Status — 2026-06-24

**Working:** the app builds, installs, renders Markdown in a clean dark window,
and **live-refreshes when the file changes on disk** — the core product. Proven
offline in the real WKWebView, with a watcher unit suite + end-to-end checks.

**v2 (2026-06-24) — normal-app features** (PRD-v2.md, all 22 steps built; 14 XCTests green): Settings window (⌘,), **Dark + Light themes**, font **zoom** (⌘+/-/0), content width, **⌘F find** with match count, **outline sidebar** (⌥⌘1), **print + export PDF/HTML**, always-on-top (⌃⌘T), copy path (⌘L) + drag-to-open, window-frame + scroll memory, **GFM** task lists/footnotes/deflists/strikethrough, **LaTeX math** (KaTeX, offline, toggle), **custom CSS** (live-watched), CLI installer, Sparkle auto-update *plumbing* (inert until a release host/keys/notarization exist). Still offline-only; ad-hoc signed for local use.

### Built & verified
- **Project scaffold** — XcodeGen (`project.yml`) → Xcode project; Swift, macOS 13+, builds unsigned for local dev.
- **Markdown rendering** — bundled **markdown-it 14.1.0** + **highlight.js 11.10.0** in a `WKWebView`, 100% offline. Headings, bold/italic, inline + fenced code with **syntax highlighting**, lists, tables, blockquotes, links, images all render.
- **Dark theme** — GitHub-dark-style (`theme.css`), readable, code panels, bordered tables.
- **Window management** — AppKit `WindowManager`: one window per file, deduped (re-open focuses), clean teardown, sane default size (820×720, resizable).
- **Finder integration** — registers as a Markdown viewer (`.md` / `.markdown`); can be set as default app.
- **App icon** — dark `M⌄` mark (`MDLive.icns`).
- **Verification** — headless self-test reads the rendered DOM back (`<h1>Hello, MDLive</h1>`, `hljs-keyword`, `<blockquote>`); GUI window-open verified via marker (one window per file, no spawn loop).

### Live refresh + app polish (Steps 6–11, done 2026-06-24)
- **Step 6 — live file watching.** FSEvents on the parent dir + 150ms debounce + (mtime,size)-stable guard; scroll-preserving incremental re-render. Verified: external write **and** atomic replace both auto-refresh; watcher XCTest suite green.
- **Step 7 — robustness.** 1s poll fallback; survives 50-write bursts (debounced to ~2 renders), delete, recreate, partial writes — no crash.
- **Step 8 — menus + ⌘R.** AppKit main menu: Open ⌘O, Open Recent (UserDefaults), Reveal ⌘⇧R, Close ⌘W, Refresh ⌘R.
- **Step 9 — empty + error states.** Exact §5.5 strings, error overlay, empty state.
- **Step 10 — multi-window isolation.** One watcher per window; editing one window doesn't touch others; clean teardown on close (unit-tested).
- **Step 11 — signing.** Ad-hoc signed for local use (`scripts/build-and-sign.sh local`). Developer-ID notarization scripted (`ship` mode) — needs an Apple Developer ID.

### Not yet built
- Step 4 — full theme/element pass (`kitchen-sink.md` checklist).
- Step 5 — `mdlive-img` path validation (DEC-13) + image fixtures.
- Step 11 ship tier — Developer-ID notarization (needs Apple Developer ID).

## Build & run

```
brew install xcodegen
cd /Users/work/Personal/MDLive
xcodegen generate
xcodebuild -project MDLive.xcodeproj -scheme MDLive -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath build/dd build
```

Install to /Applications and open a file:

```
cp -R build/dd/Build/Products/Debug/MDLive.app /Applications/MDLive.app
open -a MDLive sample/hello.md
```

> Note: `open -a` against the raw DerivedData path fails with Launch Services
> error -600 — install to `/Applications` (above) and launch by name.

Headless render self-test:

```
MDLIVE_SELFTEST=/tmp/out.json MDLIVE_OPEN="$PWD/sample/hello.md" \
  /Applications/MDLive.app/Contents/MacOS/MDLive
cat /tmp/out.json   # rendered DOM readback
```

## Architecture (current)

```
MDLiveApp (SwiftUI, Settings-only scene)
  AppDelegate.application(_:open:) ─→ WindowManager.open(url)   (Finder/Open With)
WindowManager (AppKit)  ─ one NSWindow per file, deduped
  └─ NSHostingController(DocumentView)
       └─ PreviewModel (reads file)  →  WebRenderer (NSViewRepresentable)
            └─ WebKitRenderer  ─ WKWebView + mdlive-img scheme + ready/link handlers
                 └─ Resources/web/  index.html · markdown-it · highlight.js · theme.css
```

Source files: `MDLive/MDLiveApp.swift`, `WindowManager.swift`, `WebRenderer.swift`,
`WebKitRenderer.swift`, `SelfTestRunner.swift`, `Resources/web/*`.

## Key decisions
markdown-it-in-WKWebView rendering · non-sandboxed, local-build-needs-no-signing ·
AppKit window management (not SwiftUI `WindowGroup`, which loop-spawned/restored
windows) · dark-always theme. Full rationale in [`PRD.md`](PRD.md) §1.
