# MDLive — Build Doc / PRD  **(LOCKED v2 — 2026-06-23)**

> **Single source of truth** for the MDLive build. Methodology: Decypher PRD-first (`/write-prd`), adapted for a **greenfield, single-repo, personal macOS app**. Dropped (don't apply here): shared DB, `preprod`/external merge gate, R01/R02/R03 role gating, pytest/Liquibase, cross-app smoke. Carried over: recon, scope discipline (IN/OUT/DEFERRED), decisions-locked, executable dependency-ordered TDD steps (Ralph-loop-ready), the PB&J pass, the testing pyramid + real-stack rule, Definition of Done.
>
> **v2 changelog:** locked after an adversarial PB&J pass. Resolved: vendored-asset provenance (versions + SHA-256 + commands), `render()` now explicitly authored, theme spec + acceptance gate + error copy inlined (no external-PRD dependency), absolute-image-path contradiction resolved, shell-load mechanism decided (`loadFileURL`), `ready` handshake made mandatory, debounce/stability timing pinned, Open Recent path decided (`UserDefaults`), all subjective acceptance criteria made checkable, DoD split into *feature-complete* vs *shippable*, OPEN-1 demoted to a deferred ship-time item. **Zero ‹OPEN› markers remain → locked.**

- **Status:** LOCKED. Buildable by a zero-context executor. Signing/notarization (Step 11) is the only thing gated on an external (the Apple Developer ID) and is explicitly *not* required for feature-complete.
- **Owner / executor:** S. Smith (local + feature-branch only; personal repo, no external merge gate).
- **Toolchain (verified 2026-06-23 on this machine):** Xcode 26.0.1, Swift 6.2, Homebrew 6.0.2, XcodeGen (brew), node 26 / npm 11 (build-time only; runtime is 100% offline).

---

## 0. Scope — IN / OUT / DEFERRED

If a capability isn't under **IN**, it doesn't get built without re-confirming. Scope creep is a gremlin in the floorboards.

### IN (MVP)
- Native macOS app (SwiftUI + AppKit glue), **macOS 13 Ventura minimum**.
- Open `.md` / `.markdown` from Finder (double-click, Open With), `File → Open` (⌘O), drag onto app icon, drag into window.
- Register as a **viewer** document handler for Markdown UTIs (does **not** claim all text files).
- Render Markdown → HTML via **bundled markdown-it** in a **WKWebView**, fully offline.
- **Syntax highlighting** in fenced code blocks via bundled **highlight.js**, offline.
- **Dark theme**, readable, applied always.
- **Live external refresh:** auto-update when another process edits the file, <500 ms, no focus required.
- **Multiple windows**, one file + one watcher each, fully isolated.
- Element coverage: headings, paragraphs, bold, italic, inline code, fenced code, links, images, blockquotes, ordered/unordered lists, tables, horizontal rules.
- Relative image path resolution (relative to the `.md` file's folder).
- Link routing: external → default browser; local `.md` → new MDLive window.
- Manual refresh (⌘R); scroll-position preservation (percentage).
- Graceful states: empty, error, recovery on file reappearance.
- Menus + shortcuts: ⌘O, ⌘R, ⌘W, ⌘Q, Reveal in Finder, Open Recent.
- Settable as the **default app** for `.md`. (Distribution signing is DEFERRED — see DEC-2/Step 11.)

### OUT (not built; would require re-confirm)
- Any editing / text input / cursor in the body. **Never writes the source file.**
- Vaults, workspaces, projects, sidebars, file trees.
- Local web server, browser tabs, CDN/network anything.
- Accounts, telemetry, analytics, sync, cloud, export, print, linting, WYSIWYG, collaboration.

### DEFERRED (post-MVP, explicit, not in the loop)
- Developer-ID signing + notarization for distribution to other machines (Step 11; gated on owning an Apple Developer ID).
- Theme toggle (Dark/Light/System) + light CSS — dark-always ships first (DEC-4).
- Settings pane (font size, content width, auto-refresh toggle, polling speed).
- Font-size shortcuts, ⌘L copy path, ⌘⇧R reveal, exact-offset/anchor scroll.
- Mermaid, LaTeX math, custom CSS, PDF/HTML export, print.
- Always-on-top / pin window *(strong fit for the AI workflow — easy v1.1)*.
- CLI helper (`mdlive file.md`); extra extensions (`.mdown`, `.mkd`, `.txt`).

---

## 1. Decisions locked

| # | Decision | Basis |
|---|----------|-------|
| **DEC-1** | **Render = bundled markdown-it in a WKWebView.** Swift reads file → JS `render()` → DOM. | Best GFM/table support, trivial CSS theming, on-ramp to highlight.js/Mermaid/math. Beats native swift-markdown (weak tables/images, hard to theme). |
| **DEC-2** | **Distribution = direct, non-sandboxed.** **Local dev/use needs NO signing** (ad-hoc / "Sign to Run Locally"); Developer-ID signing + notarization is DEFERRED to ship-time (Step 11). | Core value = watching arbitrary files. Sandbox forces per-file security-scoped bookmarks. A locally-built `.app` from DerivedData isn't quarantined → Gatekeeper doesn't nag on your own Mac. |
| **DEC-3** | **Syntax highlighting = in MVP**, bundled highlight.js 11.10.0 "common" build, offline. | Trivial on markdown-it; right look day one. |
| **DEC-4** | **Theme = dark always for MVP**; toggle deferred. | PRD dark-first direction; one theme = less CSS. |
| **DEC-5** | **Scaffolding = XcodeGen** (`project.yml` → generated `.xcodeproj`, gitignored). | Project in a checked-in text file: reproducible, loop-friendly. |
| **DEC-6** | **Windows = AppKit `WindowManager`** (one deduped `NSWindow` per file, hosting a SwiftUI `DocumentView` via `NSHostingController`); `@NSApplicationDelegateAdaptor` + `application(_:open:)` route Finder/Open-With/drag URLs to `WindowManager.open`. App's only SwiftUI Scene is `Settings`. **(Amended in build:** the original `WindowGroup(for: URL.self)` value-scene approach loop-spawned windows and resurrected stale value-windows via state restoration — verified bug. AppKit gives deterministic one-window-per-file + clean teardown, which Step 10 needs anyway.) | Beats `DocumentGroup` (snapshot fights live watching) and `WindowGroup(for:)` (restoration ghosts + drain races). |
| **DEC-7** | **Watching = FSEvents on the PARENT DIRECTORY**, filtered to the filename; on event, **debounce 150 ms**, then sample `(mtime,size)` twice 60 ms apart and re-read only when both samples are equal; **1.0 s Timer polling fallback**. | An fd watch goes deaf on atomic-replace/temp-move (how agents/editors save). Dir watch survives replace/delete/recreate. Stability sampling avoids reading mid-write. (LESSON-2/3.) |
| **DEC-8** | **Local images = custom `WKURLSchemeHandler` for scheme `mdlive-img`**; markdown-it rewrites relative img `src` → `mdlive-img://<percent-encoded-abs-path>`. Handler serves bytes only for canonicalized paths **under the open file's directory** (recursive, symlinks resolved); anything outside → 403. | Sidesteps WKWebView `file://` subresource blocking (LESSON-1). |
| **DEC-8a** | **Shell load = `webView.loadFileURL(indexURL, allowingReadAccessTo: web/)`** for the bundled `index.html`/JS/CSS. No `mdlive-res` scheme (dropped — one mechanism only). | Bundle assets are siblings → one read-access grant covers them; avoids a second scheme handler. |
| **DEC-9** | **Refresh = incremental JS re-render** (`render()` swaps `#content.innerHTML`), never `reload()`. | Preserves scroll, no flicker, fast. |
| **DEC-10** | **Scroll preservation = percentage** of scroll height (capture before, reapply after re-render). | PRD §10.5 MVP bar. |
| **DEC-11** | **Local `.md` link → new MDLive window; `http(s)`/`mailto` → default app via `NSWorkspace`; other local file → `NSWorkspace.open`.** Relative targets resolve against the open file's directory. | PRD §10.7/§22.7; new window keeps watchers isolated. |
| **DEC-12** | Doc types: role **Viewer**; declare UTI `net.daringfireball.markdown` (imported) covering exts `md`,`markdown`; `CFBundleDocumentTypes.LSItemContentTypes = [net.daringfireball.markdown]`; `LSHandlerRank = Alternate`. Do **not** reference the non-standard `public.markdown`. | PRD §10.2 — viewer only, don't seize `.txt`. |
| **DEC-13** | **Image path-validation rule (resolves the rule-#5 contradiction):** canonicalize the resolved path (resolve symlinks); serve **iff** it has the open file's directory as a prefix. Absolute paths *outside* that dir are **rejected**, even though they're "absolute" — this overrides any "absolute passes through" reading. `http(s)` image URLs are left untouched (load only if online; not our CDN). | Security + determinism; no `/etc/...` exfil via a crafted `.md`. |

---

## 2. Recon notes

Greenfield: no prior code; shared-consumer risk N/A. Recon = pinning the external API risks that bite macOS Markdown viewers, sequenced to de-risk early:

- **R-A — WKWebView + local images.** #1 silent failure (blank images, no error). → DEC-8 custom scheme. Step 5.
- **R-B — Atomic-replace watching.** fd watch goes deaf on `rename()`-over. → DEC-7 dir watch. Step 6.
- **R-C — Partial writes.** Mid-write reads = truncated/invalid. → debounce + `(mtime,size)`-stable guard + never-crash. Step 6/7.
- **R-D — Finder "Open With" plumbing.** Non-`DocumentGroup` apps must receive opens via the app delegate **and** be registered with Launch Services to appear in Open With. → DEC-6 + `lsregister`. Step 1/2.
- **R-E — Notarization gate.** Needs a real Developer ID. → isolated to Step 11; Steps 0–10,12 run unsigned. (DEC-2.)

---

## 3. Architecture

```
MDLiveApp (SwiftUI App)
  @NSApplicationDelegateAdaptor → AppDelegate.application(_:open:)  ← Finder/Open With/drag-on-icon
       └─ forwards URLs → openWindow(value: URL)
  WindowGroup(for: URL.self) { PreviewScene(url:) }
  Commands { ⌘O ⌘R ⌘W Reveal-in-Finder Open-Recent(UserDefaults) }
        │ one per window
        ▼
  PreviewModel (per window, @Observable): url, state(.empty/.ok/.error), owns one FileWatcher,
        reads file → hands (markdown, baseDir, scrollPct) to WebRenderer
        │                                  │
        ▼                                  ▼
  FileWatcher                         WebRenderer (NSViewRepresentable → WKWebView)
   FSEvents on parent dir,             loadFileURL(index.html, allowingReadAccessTo: web/)  [DEC-8a]
   filter name, debounce 150ms,        WKURLSchemeHandler "mdlive-img" → validated local bytes [DEC-8/13]
   (mtime,size)-stable guard,          message handlers: "ready" (mandatory), "link"
   1.0s poll fallback                  evaluateJavaScript("render(md, opts)")  [DEC-9]
        │ loads (offline)
        ▼
  MDLive/Resources/web/: index.html · markdown-it.min.js · highlight.min.js · highlight-dark.css · theme.css
```

One-directional: disk → PreviewModel (Swift) → JS `render()` → DOM. WebView never writes; Swift never mutates the source.

---

## 4. Requirements & behavior rules

1. **Read-only always.** No write path to the source file.
2. **Refresh triggers:** content change, mtime change, atomic replace, delete→recreate at same path. No focus/reload/reopen.
3. **Debounce burst writes** (DEC-7) → render once at settle; never mid-write.
4. **Never crash** on malformed/partial/transient-fail input: keep last good render, recover on next good read.
5. **Images** resolve per DEC-8/DEC-13.
6. **Links** route per DEC-11; the WebView itself never navigates away from the shell.
7. **Window title = file name** (basename incl. extension); subtitle optional.
8. **Multi-window isolation:** one watcher per window; close tears it down (no leaked FSEvent stream / timer — assert via `deinit`).
9. **Error copy** = human-readable, with path + cause, exact strings in §5.5. No stack traces.
10. **Idle = cheap:** event-driven FSEvents; 1.0 s poll fallback only.
11. **Selectable text**, reduce-motion respected, WCAG-AA contrast (≥4.5:1 body text).

---

## 5. Interface contracts (names are the contract — keep code, doc, tests aligned)

### 5.1 JS `render()` — authored in `index.html` (Step 3 authors it; Step 3+ call it)
```js
// Signature called from Swift via evaluateJavaScript:
render(markdown /*string*/, opts /*{ baseDir:string, scrollPct:number }*/) -> void
```
Behavior the authored implementation MUST have:
- `markdown-it` configured `{ html:false, linkify:true, typographer:false }` + tables (on by default in markdown-it) ; fenced code → `hljs.highlightElement`.
- Rewrite each relative image `src` → `mdlive-img://` + `encodeURIComponent(absolutePath)` where `absolutePath = opts.baseDir + '/' + src` (skip `http(s):` and already-absolute `mdlive-img:` srcs).
- Tag `<a>` whose href is `http(s)`, `mailto`, or ends `.md`/`.markdown` (or is otherwise local) with `data-mdlive-link`; one delegated click handler calls `window.webkit.messageHandlers.link.postMessage(href)` and `preventDefault()`.
- Capture nothing itself; **caller passes `scrollPct`**; after `#content.innerHTML = html`, set `document.scrollingElement.scrollTop = opts.scrollPct * document.scrollingElement.scrollHeight`.
- DOM swap only — **no reload**.
- On load, post `window.webkit.messageHandlers.ready.postMessage(true)` so Swift knows the first `render()` won't be dropped.

### 5.2 Custom scheme — `mdlive-img://<percent-encoded-abs-path>` (DEC-8/DEC-13)
Handler: percent-decode → canonicalize (resolve symlinks) → require prefix == canonicalized open-file directory → read bytes, set MIME by extension (`png/jpg/jpeg/gif/svg/webp` → respective; else `application/octet-stream`) → respond. Outside-dir or unreadable → HTTP 403/404 response (never crash).

### 5.3 Swift message handlers (WKScriptMessageHandler)
- `ready` — **mandatory**; gates the first `render()` call.
- `link` — receives clicked href → routes per DEC-11.

### 5.4 FileWatcher → model
Emits debounced `.changed` (after `(mtime,size)` stable per DEC-7), `.deleted`, `.appeared`. Model re-reads on `.changed`/`.appeared`; `.deleted` → error state but **keep watching the directory** for recovery.

### 5.5 Error/empty copy (exact strings)
- Empty state title: `Open a Markdown file` · body: `MDLive previews Markdown and refreshes when the file changes on disk.` · button: `Open File…`
- File missing: `Can't find this file — it may have been moved or deleted.\n<path>`
- Permission denied: `MDLive doesn't have permission to read this file.\n<path>`
- Unreadable/encoding: `This file isn't readable as text (UTF-8).\n<path>`
- Transient (kept last good render): small status text `Reloading…` then clears.

### 5.6 Theme spec (inlined; was external PRD §19)
- Background `#0d1117` (deep blue-black). Body text `#e6edf3`. Muted/secondary `#8b949e`.
- Links `#4493f8` (no underline until hover). Headings `#f0f6fc`, `h1/h2` with a `1px solid #21262d` bottom divider.
- Inline code: bg `#161b22`, text `#79c0ff`, `2px 5px` padding, `6px` radius.
- Code block panel: bg `#161b22`, `1px solid #30363d`, `12px 14px` padding, `8px` radius, horizontal scroll, syntax colors from `highlight-dark.css` (github-dark).
- Tables: `1px solid #30363d` borders, header bg `#161b22`, `6px 12px` cell padding, wrap in an `overflow-x:auto` container.
- Blockquote: `4px solid #30363d` left border, muted text, no loud bg.
- `hr`: `1px solid #21262d`. Body: max-width `860px`, `32px` padding, system font stack, `16px`/`1.6`.

---

## 6. Test strategy (pyramid + real-stack rule) — all acceptance objective

- **XCTest unit (deterministic safety net):**
  - `FileWatcher` debounce: N writes in <150 ms → **exactly 1** `.changed` (assert count).
  - stability guard: growing-size samples → no emit until two equal `(mtime,size)` samples.
  - atomic replace: write temp + `rename()` over target → exactly 1 `.changed`, watcher still live (a later write also fires).
  - delete→recreate → `.deleted` then `.appeared`.
  - `ImageResolver`: relative→abs under dir; `../escape` → rejected; `http(s)` passthrough; absolute-outside-dir → rejected (DEC-13).
  - `LinkRouter`: classify `http`/`mailto`/`.md`/other-local correctly (string assertions).
- **Node `render()` unit (offline, `web-tests/`):** load `markdown-it.min.js`, feed sample MD, assert output HTML **contains**: `<table>`, a `<code class="hljs` token, `src="mdlive-img://`, `data-mdlive-link`. Pure string assertions, no network.
- **Real-stack acceptance (REQUIRED before "feature-complete" — don't trust unit green):**
  - **Self-test harness:** app launched with env `MDLIVE_SELFTEST=<outpath> MDLIVE_OPEN=<md>` opens the md, renders, reads back `#content.innerText` + `innerHTML` via `evaluateJavaScript`, writes them to `<outpath>`, exits 0. → assert file contains expected rendered text. (This is the objective "it really rendered" gate without needing a human to look.)
  - Visual: `sample/kitchen-sink.md` shows all 12 elements (checklist), code highlighted, AA contrast (contrast-checker on the spec colors — pre-verified in §5.6).
  - Live edit: external write → preview updates **<500 ms** (timestamp the write and the readback); scroll top within **±5%** of pre-edit `scrollPct`.
  - Atomic replace: `mv tmp target.md` → readback equals new content.
  - Rapid rewrite: 50 writes fast → process alive (exit code check), final readback **string-equals** the final file's rendered text, render-count ≤ writes (no per-write storm; assert via a JS render counter).
  - Missing/recreated, permission-denied: error string per §5.5; recreate → recovers.
  - 10 MB doc (generated, see Step 12) opens, stays responsive (<2 s to first render).
  - Two windows independent; close one → its `FileWatcher.deinit` log fires, no further `.changed` for that file in 10 s.
  - **Zero network:** `nettop`/Little Snitch shows no outbound connection for an open doc.

---

## 7. Executable steps (Ralph-loop-ready)

One increment per step; do → run acceptance → commit → read diff → next. Update `PROGRESS.md` each step. Pure-Swift logic is TDD (test first). All commands single-line (harness rule). Steps 0–10,12 use **no signing**.

> **Step 0 — Toolchain + skeleton.**
> Prereqs (verify): `xcode-select -p` points to Xcode ≥15; `xcodegen` installed (`brew install xcodegen`). Create dirs (`MDLive/Resources/web`, `MDLiveTests`, `web-tests`, `sample/assets`), `git init`, `.gitignore` (`*.xcodeproj`, `DerivedData/`, `.DS_Store`). Author `project.yml` (skeleton below; bundle id default `com.ssmith.MDLive`, name `MDLive`, deploymentTarget macOS `13.0`, `CODE_SIGNING_ALLOWED: NO` baseline). Add a minimal `MDLiveApp.swift` showing one empty `WindowGroup`. `xcodegen generate`.
> **project.yml skeleton:**
> ```yaml
> name: MDLive
> options: { bundleIdPrefix: com.ssmith, deploymentTarget: { macOS: "13.0" } }
> settings: { base: { CODE_SIGNING_ALLOWED: "NO", CODE_SIGN_IDENTITY: "", PRODUCT_BUNDLE_IDENTIFIER: com.ssmith.MDLive } }
> targets:
>   MDLive:
>     type: application
>     platform: macOS
>     sources: [MDLive]
>     info: { path: MDLive/Info.plist, properties: { LSMinimumSystemVersion: "13.0", NSHumanReadableCopyright: "" } }
>   MDLiveTests:
>     type: bundle.unit-test
>     platform: macOS
>     sources: [MDLiveTests]
>     dependencies: [{ target: MDLive }]
> ```
> **Accept:** `xcodegen generate` exits 0; `xcodebuild -project MDLive.xcodeproj -scheme MDLive -configuration Debug CODE_SIGNING_ALLOWED=NO build` exits 0; `open` the built `.app` (path from `xcodebuild -showBuildSettings ... BUILT_PRODUCTS_DIR`) shows one empty window. Commit.

> **Step 1 — Document type registration (R-D, DEC-12).**
> In `Info.plist` via `project.yml`: `CFBundleDocumentTypes` (role Viewer, `LSItemContentTypes: [net.daringfireball.markdown]`, `LSHandlerRank: Alternate`) + `UTImportedTypeDeclarations` redeclaring `net.daringfireball.markdown` (conforms to `public.plain-text`, exts `md`,`markdown`). After build: `lsregister -f <BUILT_PRODUCTS_DIR>/MDLive.app` (lsregister at `/System/Library/Frameworks/CoreServices.framework/.../lsregister`).
> **Accept:** after lsregister, `mdls`/Finder right-click → Open With lists MDLive for a `.md`. Commit.

> **Step 2 — Window-per-file + Finder open (DEC-6).**
> `WindowGroup(for: URL.self)` + `@NSApplicationDelegateAdaptor`; `AppDelegate.application(_:open:)` → `openWindow(value:)`. `File→Open` (⌘O) via `NSOpenPanel` with `allowedContentTypes = [UTType(filenameExtension:"md"), .init("net.daringfireball.markdown")].compactMap{$0}`. Window title = basename.
> **Accept:** `open -a MDLive sample/hello.md` (created in Step 3 — for this step use a temp `echo "# hi" > /tmp/x.md`) opens a window titled `x.md`; ⌘O opens a second window. Commit.

> **Step 3 — Static render pipeline (DEC-1/8a/9; authors `render()`).**
> Vendored assets already present in `MDLive/Resources/web/` (markdown-it 14.1.0, highlight.js 11.10.0, highlight-dark.css — see §provenance). **Author `index.html`**: loads the three vendored files + `theme.css`, defines `render()` per §5.1, posts `ready`. **WebRenderer**: `WKWebView` with `mdlive-img` scheme handler + `ready`/`link` message handlers; `loadFileURL(web/index.html, allowingReadAccessTo: web/)`; on `ready`, `evaluateJavaScript("render(<jsonMd>, {baseDir:<dir>, scrollPct:0})")`. Create `sample/hello.md` = `# Hello, MDLive\n\nIt **renders** \`markdown\` live.`.
> **Accept:** self-test harness on `sample/hello.md` → readback file contains `Hello, MDLive` and `<strong>renders</strong>` and `<code>markdown</code>`. Commit. *(This is the goal-state gate.)*

> **Step 4 — Dark theme + element coverage (§5.6).**
> Author `theme.css` exactly per §5.6 + load `highlight-dark.css`. Build `sample/kitchen-sink.md` covering all 12 elements.
> **Accept:** self-test readback `innerHTML` contains `<h1>`,`<table>`,`<blockquote>`,`<pre>`,`<code class="hljs`,`<ul>`,`<ol>`,`<hr>`,`<em>`,`<strong>`,inline `<code>`,`<a `. Commit.

> **Step 5 — Relative images + link routing (R-A, DEC-8/11/13).**
> `mdlive-img` handler serves validated bytes; markdown-it rewrites relative img `src`; `link` handler routes per DEC-11. Create `sample/with-image.md` (refs `assets/demo.png` + an `http` link + `[other](other.md)`), `sample/other.md`, and generate `sample/assets/demo.png` via `sips`/a tiny base64 PNG.
> **Accept:** self-test readback shows `src="mdlive-img://` for the image and `data-mdlive-link` on both links; manual: image visible; external link → browser; `.md` link → new window. Commit.

> **Step 6 — Live watching + incremental refresh (R-B/C, DEC-7/9/10).** *(TDD: §6 watcher tests first.)*
> `FileWatcher` per DEC-7. On `.changed`: re-read → capture scrollPct (read back via JS) → `render(...)` (DOM swap) → restore.
> **Accept:** XCTest watcher suite green; live self-test: external write → readback updated, timestamp delta **<500 ms**; scrollPct within ±5%; `mv tmp file.md` → updated. Commit.

> **Step 7 — Polling fallback + robustness (R-C).**
> 1.0 s `Timer` fallback (compare mtime+size). Missing→error+keep watching; recreate→recover; permission→error; UTF-8 decode failure→keep last good render + `Reloading…` notice.
> **Accept:** 50-fast-writes self-test: process exit 0, final readback string-equals final content, JS render-count ≤ 50; `rm`→§5.5 missing string; recreate→recovers; `chmod 000`→§5.5 permission string. Commit.

> **Step 8 — Manual refresh + menus.**
> ⌘R re-read+re-render. Menus: File (Open, Open Recent [**UserDefaults**-backed list, DEC-6 — not NSDocumentController], Close ⌘W, Reveal in Finder), View (Refresh). ⌘Q quits; ⌘W closes front window.
> **Accept:** each item works; Reveal selects source in Finder; Open Recent (after opening 2 files) relists+reopens them. Commit.

> **Step 9 — Empty + error states (§5.5 exact strings).**
> No-file launch → empty state (§5.5). Read failure → error panel (§5.5) with path.
> **Accept:** launch with no arg → empty-state strings present; open `/tmp/nope.md` → missing-file string, no stack trace. Commit.

> **Step 10 — Multi-window isolation.**
> One watcher/window; `FileWatcher.deinit` logs; teardown on window close.
> **Accept:** two files open, edits independent; close one → its `deinit` log fires, no `.changed` for it in 10 s. Commit.

> **Step 11 — Sign + notarize (DEFERRED / ship-time; gated on Developer ID — NOT required for feature-complete).**
> Set `CODE_SIGN_IDENTITY` to Developer ID Application; `xcodebuild ... archive` → export; `xcrun notarytool submit <zip> --keychain-profile <profile> --wait`; `xcrun stapler staple`; `spctl -a -t exec -vv <exported>/MDLive.app`. Needs Apple Developer ID + a stored notarytool keychain profile.
> **Accept:** `spctl` → "accepted, notarized"; double-click `.md` with MDLive set default opens it.

> **Step 12 — Daily-driver stress pass (feature-complete ship gate).**
> Generate 10 MB doc: `python3 -c "open('sample/big.md','w').write(('# H\n\nlorem **ipsum** \`x\`\n\n')*200000)"`. Run real Claude Code editing a watched file; atomic replace; missing/recreated; two windows.
> **Accept:** the §6 real-stack matrix all green-or-documented; live external-edit demo works end-to-end. Tag build.

**Asset provenance (pinned, offline-verifiable):** `MDLive/Resources/web/` contains —
`markdown-it.min.js` markdown-it@14.1.0 sha256 `38c70a1e7ca91ab40e2d9e6e60129851a717ed1c7d4acbbdd41bf9503791cf68`;
`highlight.min.js` @highlightjs/cdn-assets@11.10.0 sha256 `471ef9ae90c407af440fcdc48edfeeb562106b3267bd12d99071c162fb52ed32`;
`highlight-dark.css` github-dark@11.10.0 sha256 `9f208d022102b1d0c7aebfecd8e42ca7997d5de636649d2b31ea63093d809019`.
Re-fetch: `curl -sS -o <f> https://cdn.jsdelivr.net/npm/<pkg>@<ver>/<path>` then `shasum -a 256` must match.

---

## 8. PB&J pass — resolved (adversarial fresh-agent dry-run, 2026-06-23)

All top gaps from the dry-run are closed in v2: asset provenance (pinned + sha + commands), `render()` authored (§5.1/Step 3), external-PRD specs inlined (theme §5.6, error copy §5.5, acceptance gate = self-test harness §6/Step 12), shell-load decided (`loadFileURL`, DEC-8a; `mdlive-res` dropped), `ready` mandatory (§5.3), image path-validation contradiction resolved (DEC-13), debounce/stability timing pinned (DEC-7), Open Recent = UserDefaults (Step 8), all subjective accepts made objective (self-test readback, ±5% scroll, render-count, exit codes, contrast pre-verified), samples/fixtures created in the steps that reference them, exact tool invocations given (xcodebuild flags, lsregister, notarytool, 10 MB generator), DoD split (§9). **Zero ‹OPEN› markers → locked.**

---

## 9. Repo layout, branch & "PR" plan

```
MDLive/
  PRD.md  PROGRESS.md  project.yml  .gitignore  README.md
  MDLive/  MDLiveApp.swift AppDelegate.swift PreviewScene.swift PreviewModel.swift
           FileWatcher.swift WebRenderer.swift LinkRouter.swift ImageResolver.swift Info.plist
           Resources/web/  index.html theme.css markdown-it.min.js highlight.min.js highlight-dark.css
  MDLiveTests/  (XCTest: watcher, resolver, router)
  web-tests/    (node render() test)
  sample/  hello.md kitchen-sink.md with-image.md other.md big.md assets/demo.png
```
Single personal repo: `main` + short `feat/*` branches; you own all merges. **Push boundary honored:** prep locally; **no `git push` / PR until you say "push and PR."** No remote configured yet (local-only default).

---

## 10. Open questions / owners — NONE blocking (all resolved or deferred)

| # | Item | Disposition |
|---|------|-------------|
| Developer ID | Sign/notarize for *distribution to other machines* | **Deferred to Step 11**; not needed for local build/use or feature-complete. Decide at ship time. |
| Bundle id / name | — | **Resolved:** `com.ssmith.MDLive`, "MDLive" (change later is a one-line `project.yml` edit). |
| Remote git host | — | **Resolved:** local-only until explicit "push and PR." |

---

## 11. Definition of Done — two tiers

**Tier 1 — Feature-complete (the MVP target; no signing):**
1. XCTest suite green (watcher/resolver/router); node `render()` test green.
2. §6 real-stack matrix green-or-documented; **zero network** confirmed; **self-test readback proves real rendering**.
3. PRD §6 daily-driver demo (Step 12) works end-to-end with a real external editor / Claude Code.
4. Docs match code: this PRD + `PROGRESS.md` current; §5 contract names == code; `README.md` (build + "set as default") exists.
5. Doc gate: zero ‹OPEN›, every step's acceptance green (Steps 0–10, 12).

**Tier 2 — Publicly shippable (post-MVP):**
6. Developer-ID signed + notarized `.app` (Step 11) that opens `.md` from Finder on a clean macOS 13+ machine and passes `spctl`.

**Done ≠ distributed.** Tier 1 is the goal of this build; Tier 2 waits on the Developer ID.

---

## 12. Lessons / risks (append as the build teaches us)

- **LESSON-1 — WKWebView `file://` images silently fail.** Use the `mdlive-img` scheme handler with path validation (DEC-8/13). Shell itself loads fine via `loadFileURL` + read-access grant (DEC-8a) because assets are bundle siblings.
- **LESSON-2 — fd watch goes deaf on atomic replace.** Watch the directory, filter the name (DEC-7).
- **LESSON-3 — read mid-write = garbage.** Debounce + `(mtime,size)`-stable before re-read; tolerate truncated input (DEC-7, rule #4).
- **LESSON-4 — full reload nukes scroll + flickers.** Swap `#content.innerHTML`, restore scroll % (DEC-9/10).
- **LESSON-5 — notarization can't be shortcut.** Isolate to the last step; everything else builds unsigned (DEC-2).
- **LESSON-6 — don't claim all text files.** `LSHandlerRank: Alternate` + Markdown UTI only (DEC-12). And `public.markdown` is non-standard — declare `net.daringfireball.markdown`.
- **LESSON-7 — Launch Services caching.** A fresh unsigned `.app` won't show in Open With until `lsregister -f` (R-D/Step 1).
```
