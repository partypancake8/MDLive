# PRD: MDLive v2: "normal app" feature set (find · settings · themes · outline · export · math · …)

**Ticket:** n/a (personal project) · **Author:** S. Smith · **Date:** 2026-06-24 · **Status:** **LOCKED + BUILT** (PB&J-passed; all 22 steps V0-V22 implemented 2026-06-24, build clean w/ Sparkle, 14 XCTests green, harness-verified; GUI-only gates flagged manual-visual in PROGRESS.md)

> Adds the standard native-macOS-viewer features on top of shipped v1 (`PRD.md`, Steps 0-11: render + live-watch + multi-window + menus + ad-hoc signing). Permanent change, additive only, v1 behavior is preserved (§ Work already completed, § Reuse). Built on `RECON-v2.md` (Phase-0 recon, done first). Single personal repo; **held at the push line** until the literal "push and PR". Decypher PRD-first methodology, greenfield/single-repo variant.

## Scope: read first

> **The build boundary. If a capability isn't under IN, it isn't built without re-confirming.** Codes (V0…V22) tie each line to its Step.

| | |
|---|---|
| **IN (this build)** | Find ⌘F (V8); Settings window ⌘, (V1-V2); Dark+Light themes (V6); zoom ⌘+/-/0 (V7); content width (V9); window-frame memory (V11); copy path ⌘L + drag-in (V13); Outline/TOC sidebar (V10); Print + Export PDF/HTML (V18); always-on-top (V14); GFM task-lists/footnotes/deflists/strikethrough (V15); scroll-position memory (V12); About+Help (V19); LaTeX math via KaTeX, settings-gated (V16); custom CSS, live-watched (V17); CLI helper (V20); Sparkle plumbing, **inert** (V21); accessibility pass (V22). **Backbone:** shared Settings store + propagation + configurable FileWatcher (V1-V3). **Cleanup:** MVP Step 5 image-path validation (V4) + Step 4 theme/element sweep (V5). |
| **OUT (not this build, no plan)** | Mermaid diagrams; Developer-ID signing/notarization (ad-hoc local only); System (auto) theme mode; editing/vaults/sync/collaboration/App-Store/sandbox (unchanged from v1). |
| **DEFERRED (later, has owner)** | Real Sparkle distribution, host + EdDSA keys + notarization (S. Smith; § Cutover). System theme mode; per-file window frames; window tabs. |

## Contents
1. Scope · 2. How to read · 3. Source requirements (verbatim) · 4. Note from stakeholder · **4A. Interface & data contracts (§3.1 keys · §3.2 JS bridge · §3.3 assets · §3.4 watcher · §3.5 theme)** · 5. **Key terms for the executing agent** · 6. Execution protocol · 7. Current state (as-is) · 8. Work already completed (inherited) · 9. Target state / approach · 10. Decisions locked (DEC-V1..V12) · 11. Out of scope · 12. Reuse & backward-compat (v1 regression gate) · 13. Test strategy · 14. Prerequisites · 15. **Steps V0-V22** (P0 backbone → P1 reading → P2 nav/window → P3 content → P4 output/lifecycle) · 16. Definition of done · 17. Risks & mitigations · 18. Security & secrets · 19. Rollback · 20. Cutover · 21. Open questions.

## How to read this document
- Plain-English sits beside the technical detail. **Edit targets are anchored on symbols** (type/func/file names), never line numbers.
- **‹OPEN-n›** marks something only a person can answer; the executor must **never invent a value**. As of this draft **there are zero ‹OPEN› markers**, all RECON §9 questions are resolved in Decisions locked. (The Sparkle prerequisites are Cutover items, not ‹OPEN›.)
- **Similarly-named-symbol traps (PB&J):** `WebKitRenderer` (Swift, per-window WKWebView owner) vs `WebRenderer` (the SwiftUI `NSViewRepresentable` wrapper) vs `render()` (the JS fn in `index.html`), three different things. `FileWatcher` is reused for **two** purposes in v2 (the document file *and* the custom-CSS file), keep them distinct. The `mdlive-img` scheme handler is **not** the shell loader (`loadFileURL`).

## Source requirements (verbatim)
- **S. Smith, 2026-06-24 (scope):** *"do all of tier 2, and do everything in tier 3 but mermaid line, can skip apple dev id for now."* → maps to IN (Tier 2 + Tier 3 minus Mermaid minus notarization) per `RECON-v2.md` §3.
- **S. Smith, 2026-06-24 (themes):** *"theme default to dark, add a light mode and that will be it for now."* → DEC-V1 (Dark default + Light; no System mode).
- **S. Smith, 2026-06-24 (Sparkle):** *"plumbing is fine."* → DEC-V9 (integrate inert).
- The originating capability list is `RECON-v2.md` §3 (F1-F17) + the MVP gaps Step 4/5.

## Note from stakeholder
S. Smith wants MDLive to feel like a finished native macOS viewer, the "boring but expected" features (find, settings, themes, zoom, print/export, outline), without scope-creeping into an editor or a distribution project. Dark is the identity; light is a courtesy. Auto-update wiring is welcome but must not pretend to work before there's a real release pipeline. Notarization is explicitly punted. Open decisions these notes implied are resolved in Decisions locked.

## 4A. Interface & data contracts
*Names here are the contract, code, doc, and tests must agree. Referenced throughout as §3.1 (settings keys), §3.2 (JS bridge), §3.3 (assets), §3.4 (watcher), §3.5 (theme).*

**Settings is a singleton.** `Settings.shared` (a `final class … : ObservableObject`) is referenced **directly** by every consumer: including AppKit-hosted document windows. **Do NOT rely on `.environmentObject`** for document windows: they are `NSHostingController` content created **outside** the SwiftUI `Settings` scene's environment, so an injected `@EnvironmentObject` never reaches them. Each `WebRenderer.Coordinator` holds `Settings.shared` and a Combine subscription to it.

### 3.1 Settings keys (`@AppStorage`, on `Settings.shared`)
| key (property) | type | default | UserDefaults key | notes |
|---|---|---|---|---|
| `theme` | `String` (`"dark"`/`"light"`) | `"dark"` | `mdlive.theme` | DEC-V1; no system mode |
| `fontScale` | `Double` | `1.0` | `mdlive.fontScale` | clamp 0.5-3.0; ⌘+/-/0 |
| `contentWidth` | `String` (`narrow`/`medium`/`wide`/`full`) | `"medium"` | `mdlive.contentWidth` | →640/860/1100/100% |
| `autoRefresh` | `Bool` | `true` | `mdlive.autoRefresh` | FileWatcher enable |
| `pollSpeed` | `String` (`fast`/`normal`/`lowPower`) | `"normal"` | `mdlive.pollSpeed` | →0.5/1.0/3.0s |
| `customCSSPath` | `String` (empty = none) | `""` | `mdlive.customCSSPath` | live-watched |
| `mathEnabled` | `Bool` | `false` | `mdlive.mathEnabled` | KaTeX gate |
| `floatByDefault` | `Bool` | `false` | `mdlive.floatByDefault` | new windows only |

### 3.2 JS bridge (extends v1's `ready`/`link`)
Swift → JS (`evaluateJavaScript`): `applySettings({theme,contentWidth,mathEnabled,customCSS})` · `applyTheme("dark"|"light")` · `scrollToAnchor(id)` · `getOutline()`→`[{level,text,id}]` · `getScrollPct()`→Double · `serializeForExport()`→self-contained HTML. *(Zoom is Swift-side `pageZoom`; find is JS, §V8.)*
JS → Swift (message handlers): `outline` (heading list, posted at the end of `render()`). Existing `ready`/`link` unchanged.
**Sanctioned additive edits to v1's `render(markdown, opts)`** (override §12 "behavior unchanged" for exactly these): (a) at the end, post `outline` (V10); (b) on the **first** render of a document, honor `opts.scrollPct` for the initial position instead of the live-DOM `prevPct` (V12). Live-refresh still preserves the current position (v1 DEC-10).

### 3.3 Vendored assets (pin at V0; record SHA-256 in the provenance block)
| asset | version | jsdelivr path | **JS global it exposes** |
|---|---|---|---|
| markdown-it-task-lists | 2.1.1 | `markdown-it-task-lists@2.1.1/dist/markdown-it-task-lists.min.js` | `window.markdownitTaskLists` |
| markdown-it-footnote | 4.0.0 | `markdown-it-footnote@4.0.0/dist/markdown-it-footnote.min.js` | `window.markdownitFootnote` |
| markdown-it-deflist | 3.0.0 | `markdown-it-deflist@3.0.0/dist/markdown-it-deflist.min.js` | `window.markdownitDeflist` |
| markdown-it-anchor | 9.2.0 | `markdown-it-anchor@9.2.0/dist/markdownItAnchor.umd.js` | `window.markdownItAnchor` |
| katex | 0.16.11 | `katex@0.16.11/dist/{katex.min.js,katex.min.css,fonts/*}` | `window.katex` |
| @vscode/markdown-it-katex | 1.1.0 | `@vscode/markdown-it-katex@1.1.0/dist/index.umd.cjs` | `window.markdownitKatex` |
| github.min.css (light hljs) | 11.10.0 | `@highlightjs/cdn-assets@11.10.0/styles/github.min.css` | (CSS) |
KaTeX **fonts must land at `web/fonts/`** (so `katex.min.css`'s relative `fonts/KaTeX_*.woff2` resolves under the `loadFileURL` read-access root); `katex.min.css` is linked from `index.html`. markdown-it core has **strikethrough + linkify on by default**, verified, no plugin.

**Asset provenance (vendored 2026-06-24, SHA-256, globals confirmed):**
- `markdown-it-task-lists.min.js` 2.1.1, `4f3b23f4…832a81`, global `markdownitTaskLists`
- `markdown-it-footnote.min.js` 4.0.0, `d6fee58a…0c2e42`, global `markdownitFootnote`
- `markdown-it-deflist.min.js` 3.0.0, `ab393099…33692e`, global `markdownitDeflist`
- `markdownItAnchor.umd.js` 9.2.0, `9ae7874d…496d4b`, global `markdownItAnchor`
- `katex.min.js` 0.16.11, `e6bfe5de…381fd4` (+ `katex.min.css` `717bc9ae…1c4625`, `katex-auto-render.min.js` `7b57d427…6604ae`, 20 woff2 in `web/fonts/`) via `npm pack`
- `highlight-light.css` (github) 11.10.0, `3a9a5def…08cf06`
- Sparkle 2.x via SPM (`project.yml packages: Sparkle`). The `@vscode/markdown-it-katex` plugin was dropped (broken dist path) → KaTeX auto-render instead (DEC-V10).

### 3.4 FileWatcher config (DEC-V12, additive)
`FileWatcher(fileURL:, enabled: Bool = true, pollInterval: TimeInterval = 1.0, onEvent:)`, defaults keep the v1 call site (`WebRenderer.swift` `PreviewModel`) and the 4 `FileWatcherTests` compiling; `enabled=false` tears down stream+timer; interval from poll-speed.

### 3.5 Theme/CSS contract
`theme.css` gains a `[data-theme="light"]` block overriding the CSS variables (default/no-attr = v1 dark, byte-for-byte). `#content` gets a `--content-max` var (V9). A light hljs sheet is toggled by `disabled` alongside `applyTheme`. `<style id="user-css">` is appended last so custom CSS wins.

## 5. Key terms for the executing agent
Define the execution model concretely so the agent does not guess.
- **Ralph loop.** This PRD is run by an agent invoked repeatedly; **each pass is fresh** and the **repo + `PROGRESS.md` are the source of truth**. A pass: read `PROGRESS.md` + the repo, find the **first step whose gate is not green**, do **only that step** (tests-first → implement → gate → commit → update `PROGRESS.md`), stop. Re-runs are idempotent (a done step is detected and skipped).
- **`PROGRESS.md`** (repo root) is the loop's memory: per-step status, what was done, where the next pass resumes, decisions made mid-build (recorded back into Decisions locked with a date).
- **TDD (red → green → refactor).** **Red:** write the failing test first and confirm it fails for the right reason. **Green:** the minimum code to pass. **Refactor:** clean up with tests green. **Hard rules:** no production code without a failing test first; **never weaken a test to make it pass**; if an existing test contradicts the new direction, **flip it under TDD first**, don't leave it to silently pass/fail. Steps marked **ⓣ** have non-trivial logic and are strictly test-first; UI/asset steps verify via the real-stack harness (below).
- **Real-stack harness (substitutes for pytest/Playwright here).** Three observers, all env-gated and already in the v1 codebase: **self-test** (`MDLIVE_SELFTEST=<out> MDLIVE_OPEN=<md>` → renders headlessly, writes the DOM readback, exits, proves real WKWebView rendering); **GUI marker** (`MDLIVE_GUI_MARKER=<file>` → the existing internal `WebKitRenderer.flush()` (private, reads the env var itself), `WindowManager`, and `FileWatcher.deinit` append events → window-count, render-count, teardown observable without screen-recording/AX which macOS denies this process); **XCTest** (logic). "Verify in the real WKWebView, not mocks" is the rule.
- **Glossary.** *v1* = the shipped baseline (`PRD.md`). *Settings backbone* = the shared `Settings` store + propagation built in P0. *Shell* = the bundled `index.html` loaded via `loadFileURL`. *mdlive-img* = the custom WKURLSchemeHandler for local images. *Marker* = a line appended to the `MDLIVE_GUI_MARKER` file for headless verification.

## 6. Execution protocol
1. **One step at a time, in order**; do not start a step until the prior gate is green. **Tests first, confirmed red** for the right reason, then code.
2. **Run end-to-end, no per-step sign-off.** Execute steps in order without pausing (tests-first → implement → gate → commit → update `PROGRESS.md` → next). Stop only on a red gate you can't resolve, a missing-input / undefined-behavior path, or the push line.
3. **Out of bounds, never touch:** the v1 render/watch/window *contracts* except as the additive changes in §12 specify; the source Markdown file (read-only always); `build/`, `*.xcodeproj` (generated), any Sparkle private key. Use explicit `git add <files>`, never `-A`.
4. **The v1 regression gate (§12) runs after every step**, if any v1 test/self-test reddens, that step caused a regression: fix or revert before advancing.
5. On a missing input / undefined-behavior path → **stop and escalate, never guess.**
6. **Do not `git push` or open a PR** until S. Smith sends the literal **"push and PR."**

## 7. Current state (as-is, with evidence)
v1 is shipped, ad-hoc signed, installed at `/Applications/MDLive.app`. Source (`MDLive/`):
- **MDLiveApp.swift**, `@main App` with the only scene `Settings { EmptyView() }` (**placeholder, no settings UI exists**); `AppDelegate` (NSApplicationDelegate, NSMenuDelegate): self-test branch, `buildMainMenu()` (App/File/View/Window), env+argv open, `application(_:open:)`, `@objc openDocument/refreshDocument/revealInFinder/openRecentItem`, `menuNeedsUpdate` (Recent). **No Edit menu; no zoom/find/print/export/TOC/about-custom items.**
- **WindowManager.swift**, one `NSWindow` per file (`docs: [URL: Doc{window, model}]`, dedupe, `open/showEmptyStateIfNeeded/refreshFront/revealFront/front/windowWillClose`), `marker()` test hook, `RecentFiles` (UserDefaults). **No frame autosave, float, copy-path, scroll persistence, FindBar/Outline.**
- **WebRenderer.swift**, `DocumentView` (`@ObservedObject model`, ZStack WebRenderer+ErrorView), `PreviewModel` (`markdown/errorText/lastUpdated`, owns `FileWatcher`, `load/reload/handle`), `WebRenderer` (NSViewRepresentable), `LinkRouter`, `ErrorView`, `EmptyStateView`.
- **WebKitRenderer.swift**, WKWebView owner; `mdlive-img` scheme handler (**minimal, DEC-13 path validation NOT done**); `ready`/`link` handlers; `loadShell/render/flush(marker)/readback`. **No applySettings/zoom/print/createPDF/serialize.**
- **FileWatcher.swift**, FSEvents(parent dir)+150ms debounce+(mtime,size)-stable+1s poll; **fixed interval, always-on (no enable/interval params).** `deinit` logs + marker.
- **Resources/web/**, `index.html` (`md = markdownit({html:false,linkify:true,...})`, `render(md,opts)` with scroll-capture, click→`link`, `ready`); `theme.css` (**dark only**, CSS values inline, no `[data-theme]`); `markdown-it.min.js@14.1.0`, `highlight.min.js@11.10.0`, `highlight-dark.css`. **No md-it plugins, no anchor, no KaTeX, no light hljs.**
- **project.yml** (XcodeGen; SWIFT_VERSION 5.0, CODE_SIGNING_ALLOWED NO, INFOPLIST_FILE referenced, do **not** revert to `info:` which regenerates the plist), **Info.plist** (doc types), **MDLiveTests/FileWatcherTests.swift** (4 tests), **scripts/build-and-sign.sh** (`local` ad-hoc / `ship` notarize-documented), **sample/** fixtures.

## 8. Work already completed (inherited state): consumed contract, do NOT rebuild
v1 Steps 0-11 are built **and verified** (this author, on this machine, 2026-06-24): render pipeline (markdown-it+highlight.js offline), live file watching (FSEvents+debounce+stable-guard; atomic-replace + normal-write both refresh), 50-write robustness, delete/recreate recovery, two-window isolation + teardown (XCTest `testModelAndWatcherDeallocate`), menus, error/empty states, ad-hoc signed Release install. **v2 owns only the additive layer in §15; it must not re-implement or alter v1 behavior except per §12.**

## 9. Target state / approach
Build the **Settings backbone first (P0)**: a shared `Settings` (ObservableObject + `@AppStorage`) that every window's `WebKitRenderer` (JS sink via `applySettings`) and `FileWatcher` (Swift sink: enable/interval) observes, every feature hangs off it. **Options surfaced:** propagation via **(A) a shared `Settings` ObservableObject observed with Combine** vs (B) NotificationCenter broadcast. **Proposing (A)**, typed, testable, no string keys, matches SwiftUI. Then features in dependency order P1→P4. Everything routes through the existing Swift↔JS bridge and `WindowManager` lifecycle, **no new window model, no new render path.**

## 10. Decisions locked
*Each settled (stakeholder-directed or recon-resolved) with a basis. Live during the build, record mid-build decisions back here with a date.*
- **DEC-V1, Theme = Dark (default) + Light; no System mode.** Light via a `[data-theme="light"]` override block in `theme.css` + a light hljs theme; `applyTheme(mode)` sets the `<html>` attr. *Basis: S. Smith 2026-06-24.*
- **DEC-V2, Settings = one shared `Settings` (ObservableObject + @AppStorage)**, observed via Combine; pushed live (JS + FileWatcher sinks). *Basis: RECON Q1 (approach A).*
- **DEC-V3, Window frame = single shared `setFrameAutosaveName`; clamp to visible screen.** *Basis: RECON Q3.*
- **DEC-V4, TOC = native SwiftUI sidebar** (headings from `markdown-it-anchor`; click→`scrollToAnchor`). *Basis: RECON Q4.*
- **DEC-V5, Export HTML = self-contained single file** (inline theme + used hljs/KaTeX CSS). *Basis: RECON Q5.*
- **DEC-V6, Custom CSS = user file, live-watched via a second `FileWatcher`**, injected `<style id="user-css">` last; reset. *Basis: RECON Q6.*
- **DEC-V7, Zoom = `WKWebView.pageZoom`**, persisted; ⌘+/-/0. *Basis: RECON Q8.*
- **DEC-V8, CLI = in-app "Install Command Line Tool…"** writes `/usr/local/bin/mdlive` (`open -a MDLive "$@"`). *Basis: RECON Q9.*
- **DEC-V9, Sparkle plumbing inert** (SPM dep, `SPUStandardUpdaterController`, "Check for Updates…", placeholder `SUFeedURL`/`SUPublicEDKey`); no real updates until Cutover. *Basis: S. Smith + RECON Q7.*
- **DEC-V10, Math = KaTeX bundled offline**, gated by `Settings.mathEnabled`; fonts under `web/fonts/`. **Amended in build (2026-06-24): via KaTeX `auto-render` (post-render `renderMathInElement`), NOT a markdown-it plugin**, the `@vscode/markdown-it-katex` dist path was broken; auto-render is the standard browser path (RECON offered it). *Basis: RECON F13 + build.*
- **DEC-V11, GFM plugins vendored offline** (`task-lists`,`footnote`,`deflist`,`anchor`); checkboxes disabled. *Basis: RECON F10/F7.*
- **DEC-V12, `FileWatcher` additive config** (`enabled:Bool=true`, `pollInterval:TimeInterval=1.0`) from Settings; reused for custom-CSS watch. *Basis: RECON §2.1; additive keeps v1 callers/tests compiling (§12).*
- **DEC-V13, Find is JS-driven** (highlight `<mark>` + count via a JS `find()`), **not** `WKWebView.find` (which returns only `matchFound: Bool`, no count). *Basis: PB&J 2026-06-24, native API can't supply the match count the find bar requires.*
- **DEC-V14, Settings is a singleton (`Settings.shared`) referenced directly**, not via SwiftUI `.environmentObject`. *Basis: PB&J 2026-06-24, AppKit-hosted document windows (`NSHostingController`) are outside the `Settings` scene's environment, so an injected `@EnvironmentObject` never reaches them.*

## 11. Out of scope
Mermaid; Developer-ID/notarization; System theme; per-file window frames; window tabs; any editing/vault/sync/sandbox capability. The agent must not add these or "improve" v1 behavior beyond §12.

## 12. Reuse & backward-compatibility with v1 (the regression gate)
v2 modifies existing v1 objects, **all changes additive / non-breaking.**

| v1 object | Change | Compatibility |
|-----------|--------|---------------|
| `FileWatcher.init` | add `enabled`, `pollInterval` | **defaulted params** → existing `FileWatcher(fileURL:onEvent:)` call site + 4 XCTests compile unchanged |
| `index.html` `render()` | add sibling fns (`applySettings`/`applyTheme`/`scrollToAnchor`/`getOutline`/`getScrollPct`/`serializeForExport`) + plugins via a `buildMd(mathEnabled)` factory | `render(md,opts)` **signature unchanged**; two **sanctioned in-body additions** per §3.2 (post `outline` at end V10; honor `opts.scrollPct` on first render V12), every other behavior unchanged; v1 self-test readback stays valid |
| `WebKitRenderer` | new methods (apply/print/createPDF/serialize) | additive; `loadShell/render/readback/flush` untouched |
| `WindowManager` | frame autosave, float, copy-path, scroll, owns FindBar/Outline | additive; `open/dedupe/windowWillClose/teardown` preserved |
| `theme.css` | `[data-theme="light"]` block | additive; default (no attr) = v1 dark palette byte-for-byte |
| `MDLiveApp` menus | add Edit; extend View/File/Window/Help | additive; Open/Recent/Reveal/Close/Refresh unchanged |

**Regression gate (re-run after every step; must stay green):** v1 `FileWatcherTests` (4) · self-test render gate · e2e live-refresh (normal + atomic) · 50-write robustness · two-window isolation + teardown. Any red here = a v2-introduced regression → fix or revert before advancing.

## 13. Test strategy
- **Frameworks:** XCTest (logic) · Node `render()` unit (markup) · real-stack harness (self-test / GUI marker / readback) · VoiceOver (a11y). No pytest/Vitest/Playwright (N/A, no DB/Angular/server).
- **TDD per step:** ⓣ steps are strictly test-first. Coverage = happy + negative + idempotency + **the v1 regression gate** after each step.
- **Step→coverage map** lives in each step's *Tests first* + *Success criteria*.
- **Existing-test reconciliation:** the v1 `FileWatcherTests` stay valid by the defaulted-param compatibility (V3); no v1 test is deleted. New XCTests: Settings persistence/propagation (V1/V2), watcher config (V3), `mdlive-img` DEC-13 path validation (V4), outline extraction (V10), scroll persistence (V12), Exporter non-empty PDF + self-contained HTML (V18).
- **Fixtures:** `kitchen-sink.md` (all elements incl. task/footnote/deflist/math), `with-image.md`+`assets/demo.png`+`other.md` (V4), a temp `.css` for custom-CSS, a known-match doc for find.
- **Failure handling at runtime:** never crash on malformed md/CSS/math; keep last good render; no network at idle.

## 14. Prerequisites (pre-flight)
- Tooling present: Xcode ≥15, `xcodegen`, `node`/`npm` (build-time only), network for V0 asset fetch.
- **v1 baseline green** before Step 0: `xcodebuild … build` clean; `xcodebuild test` (4 watcher tests) green; `hello.md` self-test green.
- **Git baseline (the repo is not yet initialized).** If `git -C . rev-parse` fails, **`git init`, commit all of v1 as the baseline, and name the branch `main`** (`git checkout -b main` or `git branch -m main`), `.gitignore` already excludes `build/`, `*.xcodeproj`, DerivedData. Then branch v2: `git checkout -b feat/v2-normal-app`. (v1 on `main` is what §19 rolls back to.)
- `PROGRESS.md` exists (append a v2 section).
- **Zero ‹OPEN› markers** (confirmed, none).

## 15. Steps

Per-step block; symbol-anchored. ⓣ = strictly test-first. **Run the v1 regression gate (§12) after every step.** P0 backbone before features.

### Step 0: Pre-flight & baseline
- **Objective.** Git baseline + clean v2 branch + green v1 baseline.
- **Files.** `.git` (init if absent); `PROGRESS.md` (append v2 section); branches `main` (v1 baseline) + `feat/v2-normal-app`.
- **Tests first.** n/a (baseline capture).
- **Implementation.** **If not a git repo: `git init`, `git add` the v1 source (honoring `.gitignore`), commit, name the branch `main`.** Then `git checkout -b feat/v2-normal-app`. Record baselines: `xcodebuild … build`, `xcodebuild test` (4 watcher tests), `hello.md` self-test.
- **Success criteria (gate).** `git rev-parse` succeeds; v1 committed on `main`; on `feat/v2-normal-app`; all three baselines green; `PROGRESS.md` committed.
- **Failure handling.** Any baseline red → stop; v1 is the contract, fix the environment, don't proceed.

### P0: Cleanup + backbone

### Step V0: Vendor assets + Sparkle dependency
- **Objective.** Bundle pinned offline assets; add Sparkle (SPM).
- **Files.** `Resources/web/` (the **§3.3** assets, KaTeX fonts to `web/fonts/`); `project.yml` (Sparkle SPM: `packages: { Sparkle: { url: https://github.com/sparkle-project/Sparkle, from: 2.6.0 } }` + target `dependencies: - package: Sparkle`); the §3.3 provenance block (versions+SHA-256+**verified globals**).
- **Tests first.** n/a (asset step, checksum + build are the proof).
- **Implementation.** `curl` each pinned §3.3 version from jsdelivr; `shasum -a 256`; **open each UMD file and confirm the exact `window.*` global it defines**, recording it back into §3.3; link `katex.min.css` from `index.html`; add the Sparkle package; `xcodegen generate`.
- **Success criteria (gate).** All §3.3 assets present + checksums + confirmed globals recorded; `xcodebuild` links Sparkle (build clean); `hello.md` self-test still green.
- **Failure handling.** Checksum mismatch on re-fetch, or a plugin's actual global ≠ the §3.3 entry → stop, correct §3.3, don't proceed.

### Step V1 ⓣ: Settings store + window
- **Objective.** Shared `Settings` + a real Settings window (⌘,).
- **Files.** new `Settings.swift` (`final class Settings: ObservableObject`, `static let shared`, `@AppStorage` keys §3.1 with the exact UserDefaults key strings); new `SettingsView.swift` (TabView General/Refresh/Advanced, bound to `Settings.shared`); `MDLiveApp.swift` (`Settings { SettingsView() }`, **no `environmentObject`**; consumers reference `Settings.shared` directly per §4A, since AppKit doc windows can't receive the SwiftUI scene environment).
- **Tests first.** `SettingsTests`: set each key → re-read from `UserDefaults` (by the §3.1 key string) persists; defaults match §3.1. Confirm red (no store yet).
- **Implementation.** Define keys + the Settings UI bindings.
- **Success criteria (gate).** `SettingsTests` green; ⌘, opens the window; a value set, app relaunched, value still read from `UserDefaults` (test-checkable, not manual).
- **Failure handling.** `@AppStorage` key typo/collision → stop.

### Step V2 ⓣ: Settings propagation (JS sink)
- **Objective.** Settings reach **all** open windows live.
- **Files.** **`WebRenderer.swift`** (`Coordinator` gains a stored `AnyCancellable` subscribing to `Settings.shared.objectWillChange` and calls `renderer.applyCurrentSettings()`; this is where the per-window renderer is owned, v1 `Coordinator { let renderer = WebKitRenderer() }`); `WebKitRenderer.swift` (`applyCurrentSettings()` builds the opts dict from `Settings.shared` and `evaluateJavaScript("applySettings(…)")`; also called once on the `ready` handshake); `index.html` (`applySettings({theme,contentWidth,mathEnabled,customCSS})`).
- **Tests first.** `SettingsTests`: the opts-builder maps `Settings.shared`→dict correctly (pure fn). Real-stack: after a Settings change, readback reflects values.
- **Implementation.** Subscription in `Coordinator` (created where the renderer is); `applyCurrentSettings()` on `ready` and on each `objectWillChange`.
- **Success criteria (gate).** Changing contentWidth/theme updates an open window (marker re-render / readback); **two** open windows both update (each Coordinator subscribes); regression gate green.
- **Failure handling.** A window stays stale → confirm each `Coordinator` created a live subscription; stop if any window misses.

### Step V3 ⓣ: FileWatcher configurable (Swift sink)
- **Objective.** Auto-refresh on/off + poll speed honored.
- **Files.** `FileWatcher.swift` (additive `enabled:Bool=true`, `pollInterval:TimeInterval=1.0`; gate stream/timer on `enabled`; use `pollInterval`); `PreviewModel` (build watcher from `Settings`: `enabled=autoRefresh`, interval from `pollSpeed` map 0.5/1.0/3.0; reconfigure on change).
- **Tests first.** `FileWatcherTests` additions: with `enabled=false`, edit the file, **wait a fixed 2.0s budget** (well past debounce+poll), assert the `.changed` handler fired **0 times** (counter == 0); a separate test asserts a `pollInterval`-driven detection happens within `pollInterval + 0.5s` tolerance. **v1's 4 watcher tests must still compile + pass** (defaulted params).
- **Implementation.** Minimal gating.
- **Success criteria (gate).** New tests green; **4 v1 watcher tests green**.
- **Failure handling.** Disabling doesn't stop events → stop.

### Step V4 ⓣ: MVP Step 5: image path validation (DEC-13)
- **Objective.** `mdlive-img` serves only files under the open doc's directory.
- **Files.** `WebKitRenderer.swift`, give `ImageSchemeHandler` a `var docDir: String?` and **set it on the renderer's handler when a document loads** (the handler instance is held by the renderer, not re-created per request); validate by canonicalize (`resolvingSymlinksInPath`/`standardizedFileURL`) + require `hasPrefix(docDir)`, else respond 403. Add `sample/with-image.md` + `sample/assets/demo.png` (generate a small PNG) + `sample/other.md`.
- **Tests first.** `ImageResolverTests`: under-dir allowed; `../escape` + absolute-outside rejected; `http(s)` left untouched. Confirm red.
- **Implementation.** Validation in the handler (`render()` already rewrites relative→`mdlive-img`).
- **Success criteria (gate).** Tests green; `with-image.md` shows the image (self-test); external link→browser; `.md` link→new window; traversal blocked.
- **Failure handling.** Legit image rejected or traversal served → stop.

### Step V5: MVP Step 4: theme/element sweep
- **Objective.** Kitchen-sink renders every element in both themes; AA contrast.
- **Files.** `sample/kitchen-sink.md`; `theme.css` fixes for any gap.
- **Tests first.** Self-test readback contains: `<h1..h6>`,`<table>`,`<blockquote>`,`<pre><code class="hljs`,`<ul>`,`<ol>`,`<hr>`,`<em>`,`<strong>`, inline `<code>`,`<a`, task `<input ... disabled>`, `footnote-ref`, `<dl>`.
- **Implementation.** Build fixture; style any unstyled element.
- **Success criteria (gate).** Readback has all element tags (harness-checkable). **Manual visual:** dark + light both legible at ≥4.5:1 body contrast, flagged manual, since the headless readback returns DOM text/HTML, not computed colors (macOS denies this process screen-recording).
- **Failure handling.** Element unstyled/illegible → fix before advancing.

### P1: Reading core

### Step V6: Dark + Light themes
- **Objective.** Dark (default) + Light toggle (DEC-V1).
- **Files.** `theme.css` (`[data-theme="light"]` var overrides); bundle `github.min.css` (light hljs) + toggle its `disabled`; `index.html` `applyTheme(mode)` (set `<html data-theme>` + swap hljs sheet); `Settings.theme`.
- **Tests first.** Self-test: `applyTheme("light")` → readback `<html data-theme="light"]` + light bg var; no call → dark.
- **Implementation.** CSS var blocks + JS toggle.
- **Success criteria (gate).** Toggle works; relaunch defaults dark; regression gate green.
- **Failure handling.** Light low-contrast → adjust palette.

### Step V7: Zoom
- **Objective.** ⌘+/⌘-/⌘0 page zoom, persisted.
- **Files.** `WebKitRenderer` (`webView.pageZoom = scale`, apply on ready); `MDLiveApp` View menu (3 items → adjust `Settings.fontScale`, clamp 0.5-3.0); `Settings.fontScale`.
- **Tests first.** XCTest clamp logic; real-stack: `pageZoom` reflects `fontScale`.
- **Implementation.** Menu mutates fontScale; renderer applies.
- **Success criteria (gate).** ⌘+ raises zoom; ⌘0 → 1.0; persists across reopen.
- **Failure handling.** Zoom × content-width double-scale → confirm independent.

### Step V8: Edit menu + Find
- **Objective.** ⌘F find bar with a **match count** (`WKWebView.find` returns only `matchFound: Bool`, no count, so find is **JS-based**, not the native API).
- **Decision (record in §10 at build):** **DEC-V13, Find is JS-driven.** A `find(query)` JS fn wraps matches in `<mark class="mdlive-hit">`, returns `{count, current}`, and `findNext(forward)` moves the `mdlive-hit-active` highlight; Swift calls it and reads the count back. (Native `WKWebView.find` can't supply a count.)
- **Files.** `MDLiveApp` (new **Edit** menu, Copy/Select All wired to first-responder standard selectors `copy:`/`selectAll:` so they reach the WKWebView, plus Find ⌘F / Find Next ⌘G / Find Previous ⇧⌘G targeting the front window); new `FindBar.swift` (overlay: field, "n of m" label, prev/next, close); `index.html` (`find(query)`→`{count,current}`, `findNext(forward)`, `clearFind()`); `WebKitRenderer` (call those, surface count); `DocumentView` (overlay + ⌘F focus + Esc→`clearFind`).
- **Tests first.** Real-stack: a known doc, `find("the")` → returned `count` equals the known occurrence count (readback).
- **Implementation.** JS highlight/search + bar UI + key handling.
- **Success criteria (gate).** ⌘F shows bar; **count matches the known doc**; ⌘G/⇧⌘G cycle the active highlight; Esc closes + clears highlights; Copy/Select All still work in the WebView.
- **Failure handling.** Count wrong/highlight stuck → fix the JS; do not fall back to a count-less mechanism.

### Step V9: Content width
- **Objective.** Narrow/Medium/Wide/Full content width.
- **Files.** `theme.css` (`--content-max` var); `index.html` `applySettings` sets it (640/860/1100/100%); `Settings.contentWidth`.
- **Tests first.** Self-test readback `#content` max-width per setting.
- **Implementation.** CSS var + applySettings.
- **Success criteria (gate).** Width change → readback updates.
- **Failure handling.** Conflicts with zoom → keep independent.

### P2: Navigation & window

### Step V10: Outline / TOC
- **Objective.** Native sidebar of headings, click-to-jump (⌥⌘1).
- **Files.** `index.html` (`md.use(anchor)` with slugify; `getOutline()`→`[{level,text,id}]`; post `outline` after each render; `scrollToAnchor(id)`); `WebKitRenderer` (`outline` handler → publish to model; `scrollToAnchor` call); new `Outline.swift` (SwiftUI sidebar `List`); `DocumentView` (split + toggle); `MDLiveApp` View menu (⌥⌘1).
- **Tests first.** Node/self-test: `getOutline()` of `kitchen-sink.md` returns its headings (count + levels).
- **Implementation.** Anchor plugin + bridge + sidebar.
- **Success criteria (gate).** Sidebar lists kitchen-sink headings; click scrolls; **outline re-emits after a live refresh**.
- **Failure handling.** Anchor scroll timing off post-refresh → re-bind on each render.

### Step V11: Window frame memory
- **Objective.** Windows reopen at the last used size/position; never off-screen. (DEC-V3: a **single shared** autosave name, so a new window inherits the *last* frame, not a per-file frame.)
- **Files.** `WindowManager.makeWindow/open`, `setFrameAutosaveName("MDLiveDoc")`; **remove the existing `w.center()` / `win.center()` calls when an autosaved frame exists** (else `center()` overrides the restore, v1 calls `center()` in both `makeWindow` and `open`); after restore, clamp the frame into `NSScreen.visibleFrame`.
- **Tests first.** Clamp helper unit-test (off-screen rect → on-screen); manual resize→reopen.
- **Implementation.** Autosave name + drop redundant centering + clamp.
- **Success criteria (gate).** Resize/move, reopen → same frame; never off-screen. **First ever launch (no saved frame) → 820×720 centered**; thereafter windows inherit the shared last frame (per DEC-V3, not 820×720).
- **Failure handling.** `center()` still overrides restore, or off-screen → fix the centering/clamp.

### Step V12 ⓣ: Scroll memory per file
- **Objective.** Restore scroll on reopen; live-refresh keeps current.
- **Files.** `index.html`, add `getScrollPct()`; and **make `render()` honor `opts.scrollPct` on the FIRST render of a document** (today it always restores the live-DOM `prevPct` and ignores the passed `scrollPct`, sanctioned edit per §3.2: first render uses `opts.scrollPct`, subsequent live refreshes keep `prevPct`). `WebKitRenderer` (read `getScrollPct` on close/periodic; pass stored pct as `scrollPct` on the first render); new `ScrollMemory` (UserDefaults per path) in `WindowManager`.
- **Tests first.** `ScrollMemoryTests` store/get; real-stack scroll→close→reopen ±5%.
- **Implementation.** Persist + restore on first render; v1 live-refresh preserve unchanged.
- **Success criteria (gate).** Restore ±5%; live-refresh still holds current position.
- **Failure handling.** Restore fights refresh → first-open uses stored, refresh uses current.

### Step V13: Copy path + drag-in
- **Objective.** ⌘L copies front path; drop a file to open it.
- **Files.** `MDLiveApp` File menu (Copy Path ⌘L → `WindowManager.copyFrontPath` → `NSPasteboard`); `DocumentView` `.onDrop(of:[.fileURL])` → validate `.md`/`.markdown` → `WindowManager.open`.
- **Tests first.** Extension-check unit-test; manual ⌘L + drop.
- **Implementation.** Pasteboard + onDrop.
- **Success criteria (gate).** ⌘L pastes front path; `.md` drop opens (dedup); `.txt`/dir rejected.
- **Failure handling.** Wrong window on drop → route through `open()`.

### Step V14: Always-on-top
- **Objective.** Per-window float toggle (⌃⌘T) + default-on setting.
- **Files.** `WindowManager` (per-window `.level = .floating` toggle + state); `MDLiveApp` Window menu (⌃⌘T); `Settings.floatByDefault` (new windows only).
- **Tests first.** State: toggle → `window.level == .floating`.
- **Implementation.** Level toggle + default.
- **Success criteria (gate).** Toggle works; `floatByDefault` applies to newly opened windows.
- **Failure handling.** Retroactive float of existing → only new windows.

### P3: Content completeness

### Step V15: GFM plugins
- **Objective.** Task lists, footnotes, definition lists, strikethrough.
- **Files.** `index.html` (`md.use(taskLists, footnote, deflist)`, checkboxes **disabled**); `theme.css` (checkbox/footnote/dl styling); verify strikethrough+linkify core-on.
- **Tests first.** Node `render()`: `- [ ]`→`<input ... disabled>`; `[^1]`→`footnote-ref`; deflist→`<dl>`; `~~x~~`→`<s>`/`<del>`.
- **Implementation.** `md.use` + CSS.
- **Success criteria (gate).** Node + self-test show the markup; checkboxes disabled (never write the file).
- **Failure handling.** Checkbox enabled → force disabled (read-only invariant).

### Step V16: LaTeX math (KaTeX)
- **Objective.** `$…$`/`$$…$$` render, gated by `mathEnabled`.
- **Files.** `index.html`, a **`buildMd(mathEnabled)` factory** that constructs the markdown-it instance with the full plugin chain and **conditionally `.use(katex)`** (markdown-it can't *un-use* a plugin, so toggling rebuilds `md` and re-renders, §3.2/§12); `applySettings` calls `buildMd` + re-render when `mathEnabled` changes. `theme.css` (`.katex` dark/light). `Settings.mathEnabled` (default false). KaTeX `fonts/` at **`web/fonts/`**; `katex.min.css` linked from `index.html`.
- **Tests first.** Node/self-test: enabled → `$x^2$`→`.katex` span present; disabled → literal `$x^2$` text in readback.
- **Implementation.** `buildMd` factory; fonts load via the `loadFileURL` read-access root.
- **Success criteria (gate).** Enabled → `.katex` spans in readback; off (default) → raw `$…$` text; malformed `$…$` → KaTeX inline error node, no crash. **Manual visual:** glyphs render (no tofu), flagged manual since the headless readback can't see glyph rendering.
- **Failure handling.** Tofu = fonts unresolved → confirm `web/fonts/KaTeX_*.woff2` exist and `katex.min.css` is linked.

### Step V17: Custom CSS
- **Objective.** User CSS file, live-watched, reset.
- **Files.** `SettingsView` (file picker → `Settings.customCSSPath`; reset); `WebKitRenderer`/`index.html` (inject `<style id="user-css">` last, via `applySettings`); a **second `FileWatcher`** on the CSS path (live re-inject).
- **Tests first.** Real-stack: set → applied; edit file → re-injected (marker); reset → reverts.
- **Implementation.** Read file → inject → watch.
- **Success criteria (gate).** Pick/edit/reset all work; missing path ignored (no crash).
- **Failure handling.** Bad path crash → ignore gracefully + non-fatal note.

### P4: Output & lifecycle

### Step V18 ⓣ: Print + Export
- **Objective.** ⌘P print; Export PDF + self-contained HTML.
- **Files.** new `Exporter.swift` (`webView.printOperation(with:NSPrintInfo).run`; `webView.createPDF{Data}`→save panel; `serializeForExport()`→save panel); `index.html` `serializeForExport()` (doctype + inlined theme/hljs/KaTeX CSS + **KaTeX/code woff2 fonts inlined as `data:` URIs** so math/code aren't tofu offline + rendered `#content`); `MDLiveApp` File menu (Print ⌘P, Export PDF…, Export HTML…).
- **Tests first.** XCTest: `createPDF` → non-empty `Data`; `serializeForExport` output contains `<style>` + `<h1>` and **no external `href`/`src`** (fully self-contained).
- **Implementation.** print/createPDF/serialize.
- **Success criteria (gate).** Print dialog opens; PDF > 0 bytes; exported HTML opens standalone offline.
- **Failure handling.** HTML renders bare → ensure CSS inlined.

### Step V19: About + Help
- **Objective.** About (version/license) + basic Help.
- **Files.** `MDLiveApp` (App menu About → panel with `CFBundleShortVersionString`; Help → open a **bundled** `Help.html`/`Help.md` shipped in `Resources/web/` (the repo `README.md` is **not** in the installed `.app`), shown in a small window or via `NSWorkspace`).
- **Tests first.** Manual: About shows the version; Help opens the bundled doc.
- **Implementation.** About + Help items; bundle the help doc.
- **Success criteria (gate).** About shows version; Help opens the bundled doc (works from an installed `.app`, not just the dev tree).
- **Failure handling.** n/a (minor).

### Step V20: CLI installer
- **Objective.** In-app "Install Command Line Tool…" → `mdlive`.
- **Files.** `MDLiveApp` (menu item → write `/usr/local/bin/mdlive` = `#!/bin/sh\nopen -a MDLive "$@"`, `chmod +x`; clear alert on missing dir / permission); `scripts/mdlive` (reference copy).
- **Tests first.** Manual: after install, `mdlive sample/hello.md` opens it.
- **Implementation.** Write wrapper + perms.
- **Success criteria (gate).** `mdlive <file>` opens it; missing `/usr/local/bin` → clear message (no silent fail).
- **Failure handling.** Permission denied → instruct the sudo path, surface it.

### Step V21: Sparkle plumbing (inert)
- **Objective.** Updater wired, **inert** (DEC-V9).
- **Files.** `project.yml` (Sparkle dep, from V0); `MDLiveApp` (`SPUStandardUpdaterController`; App menu "Check for Updates…"); `Info.plist` (`SUFeedURL` placeholder, `SUPublicEDKey` placeholder, `SUEnableAutomaticChecks=NO`).
- **Tests first.** Build + launch; **no network at idle** (only on explicit check).
- **Implementation.** Updater controller → menu only.
- **Success criteria (gate).** Builds/launches with Sparkle; "Check for Updates…" present; `SUEnableAutomaticChecks=NO` set. **Manual:** confirm zero outbound connections at idle via `nettop`/Little Snitch (not harness-observable). Documented inert (§Cutover).
- **Failure handling.** Auto-check fires at launch → `SUEnableAutomaticChecks=NO`.

### Step V22: Accessibility pass
- **Objective.** AX labels on new chrome; honor reduce-motion.
- **Files.** `FindBar`/`SettingsView`/`Outline`/`EmptyStateView`/`ErrorView` (`.accessibilityLabel`/traits); reduce-motion check.
- **Tests first.** Manual VoiceOver over each new control.
- **Implementation.** Labels/traits.
- **Success criteria (gate).** VoiceOver reads each new control; no animation under reduce-motion.
- **Failure handling.** Unlabeled control → add label.

## 16. Definition of done
- Zero ‹OPEN› markers (confirmed none); every step gate green; **the v1 regression gate (§12) green**; XCTest + Node `render()` + real-stack harness all green; the real end-to-end outcome observed (dark+light both ship and are legible; find/zoom/TOC/math/custom-CSS/export verified live).
- **Zero network at idle** for an open doc (Sparkle only on explicit check).
- Docs match code: `PRD-v2.md` + `PROGRESS.md` + `README.md` updated; asset-provenance block (versions+SHA-256) present; §3 contract names == code.
- Ad-hoc signed Release build runs on this Mac (Tier-1). **Done ≠ distributed**, notarization is a Cutover item.
- Doc gate: **PB&J adversarial dry-run run, gaps fixed → status LOCKED.**

## 17. Risks & mitigations
- **Settings→multi-window propagation races** → single Combine source observed by every renderer; test with 2+ windows (V2).
- **KaTeX fonts in WKWebView** (tofu boxes / +~1MB) → fonts under `web/` covered by the read-access grant; gate math behind a setting; verify load (V16).
- **Sparkle non-code deps** (host/keys/notarization) → ship plumbing only, inert, `SUEnableAutomaticChecks=NO`; real updates are a Cutover item (DEC-V9).
- **Native find limits** (system highlight only) → acceptable; JS-find fallback noted (V8).
- **Window frame off-screen restore** → clamp to `visibleFrame` (V11).
- **Scroll-memory vs live-refresh conflict** → first-open restores stored, refresh preserves current (V12).
- **v1 regression from additive edits** → §12 gate after every step.

## 18. Security & secrets
- Local-first, offline; **no telemetry/analytics/network at idle**. Only an explicit "Check for Updates" reaches the (placeholder) feed.
- **No secrets in git:** the Sparkle **EdDSA private key never enters the repo** (only the public `SUPublicEDKey` in Info.plist at Cutover); `.gitignore` covers `build/`, `*.xcodeproj`, DerivedData.
- Custom CSS is the user's own file, loaded as **text only** (no remote fetch). The source Markdown file is **read-only**, MDLive never writes it. `mdlive-img` validates paths under the doc dir (V4), no arbitrary local file read.
- Signing: ad-hoc local only; Developer-ID is Cutover.

## 19. Rollback / back-out
- All work is additive on `feat/v2-normal-app`; **v1 is untouched on `main`.** Back-out = abandon the branch (or `git revert` per-step commits, each step is one commit). No data migration, no persisted-state break (Settings keys are new; absence = defaults). Blast radius: the app bundle only; uninstall = delete `/Applications/MDLive.app`. The CLI wrapper (V20) is removed by deleting `/usr/local/bin/mdlive`.

## 20. Cutover / deferred operational items (owner: S. Smith; not blocking DoD)
- **Developer-ID signing + notarization**, needs an Apple Developer ID (~$99/yr); run `scripts/build-and-sign.sh ship`. Until then, ad-hoc local only.
- **Sparkle real updates**, (a) hosted `appcast.xml` + zipped releases; (b) **EdDSA key pair** (public → `SUPublicEDKey`; private kept out of git); (c) ideally notarized builds. V21 ships plumbing only; updater stays inert until these exist.
- **CLI on PATH**, `/usr/local/bin` must be on the user's `PATH`; document if not.

## 21. Open questions / decisions needed
**None blocking**: all RECON §9 questions are resolved in Decisions locked (DEC-V1..V12). The only real-world prerequisites (Sparkle host/keys, notarization) are tracked as Cutover items with an owner, not ‹OPEN› markers.

---

> **PB&J pass complete (2026-06-24).** A fresh zero-context agent dry-ran Step 0 + V0-V22 + the §4A contracts against the real v1 code; all blocking gaps fixed (git baseline at Step 0; the §3.1 keys contract added; Settings→Coordinator wiring in V2; `flush()`/`render(scrollPct)` symbol drift; JS-find with count DEC-V13; singleton DEC-V14; V11 `center()`/autosave; KaTeX rebuild+fonts; self-contained-export font inlining; subjective gates flagged manual). **Status LOCKED.**
>
> **Next:** Ralph-loop build, **P0 first** (Step 0 → V0 → V1 → V2 → V3 → V4 → V5), then P1-P4. Held at the push line until the literal "push and PR."
