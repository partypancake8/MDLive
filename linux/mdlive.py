#!/usr/bin/env python3
"""
MDLive for Linux, GTK3 + WebKit2GTK shell around the same web renderer the
macOS app uses.

The macOS app is Swift/AppKit/WKWebView; none of that exists here. What ports
cleanly is everything that actually defines the product: `MDLive/Resources/web/`
(markdown-it + highlight.js + KaTeX + theme.css) and the JS contract in
`index.html`. Those files are used byte-for-byte, unmodified, WebKit2GTK is the
same WebKit engine family as WKWebView and speaks the same two dialects the
shell depends on:

  * `window.webkit.messageHandlers.<name>.postMessage(...)`  (PRD §5.3)
  * a custom `mdlive-img://` URI scheme                      (PRD §5.2)

So this file re-implements only the native shell: windows, watching, menus,
settings, find, outline, export. Behavior tracks the Swift sources one-for-one
(Settings.swift defaults, Shortcuts.swift accelerators, FileWatcher timings,
PRD §5.5 error copy). Command-key accelerators become Control.

Run:      mdlive [FILE...]
Selftest: mdlive --selftest            (headless; exits non-zero on failure)
"""

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")

from gi.repository import Gtk, Gdk, Gio, GLib, WebKit2, Pango  # noqa: E402

import json  # noqa: E402
import os  # noqa: E402
import sys  # noqa: E402
import urllib.parse  # noqa: E402

APP_ID = "com.github.partypancake8.MDLive"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def _web_dir():
    """Locate Resources/web, repo layout first, then installed layout."""
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (
        os.path.join(here, "..", "MDLive", "Resources", "web"),  # repo checkout
        os.path.join(here, "web"),                               # installed
        os.path.join(here, "..", "share", "mdlive", "web"),
        os.path.expanduser("~/.local/share/mdlive/web"),
    ):
        cand = os.path.normpath(cand)
        if os.path.isfile(os.path.join(cand, "index.html")):
            return cand
    return None


WEB_DIR = _web_dir()
CONFIG_DIR = os.path.join(
    GLib.get_user_config_dir() or os.path.expanduser("~/.config"), "mdlive"
)
SETTINGS_PATH = os.path.join(CONFIG_DIR, "settings.json")
STATE_PATH = os.path.join(CONFIG_DIR, "state.json")

MD_SUFFIXES = (".md", ".markdown", ".mdown", ".mkd", ".mdwn")

# PRD §5.5, exact strings.
EMPTY_TITLE = "Open a Markdown file"
EMPTY_BODY = "MDLive previews Markdown and refreshes when the file changes on disk."
EMPTY_BUTTON = "Open File…"
ERR_MISSING = "Can't find this file, it may have been moved or deleted.\n{path}"
ERR_PERM = "MDLive doesn't have permission to read this file.\n{path}"
ERR_ENCODING = "This file isn't readable as text (UTF-8).\n{path}"


# ---------------------------------------------------------------------------
# Settings, mirrors MDLive/Settings.swift keys, defaults and derived mappings
# ---------------------------------------------------------------------------

class Settings:
    DEFAULTS = {
        "theme": "dark",
        "fontScale": 1.0,
        "contentWidth": "medium",
        "autoRefresh": True,
        "pollSpeed": "normal",
        "customCSSPath": "",
        "mathEnabled": False,
        "floatByDefault": False,
    }

    def __init__(self):
        self._d = dict(self.DEFAULTS)
        self._listeners = []
        self.load()

    def load(self):
        try:
            with open(SETTINGS_PATH, "r", encoding="utf-8") as fh:
                stored = json.load(fh)
            if isinstance(stored, dict):
                for k, v in stored.items():
                    if k in self.DEFAULTS and isinstance(v, type(self.DEFAULTS[k])):
                        self._d[k] = v
        except (OSError, ValueError):
            pass  # missing or corrupt settings → defaults, never fatal

    def save(self):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            tmp = SETTINGS_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self._d, fh, indent=2)
            os.replace(tmp, SETTINGS_PATH)
        except OSError:
            pass

    def get(self, key):
        return self._d.get(key, self.DEFAULTS.get(key))

    def set(self, key, value):
        if self._d.get(key) == value:
            return
        self._d[key] = value
        self.save()
        for fn in list(self._listeners):
            fn()

    def subscribe(self, fn):
        self._listeners.append(fn)

    def restore_defaults(self):
        self._d = dict(self.DEFAULTS)
        self.save()
        for fn in list(self._listeners):
            fn()

    # Derived, Settings.swift `pollInterval` / `contentMaxCSS` / `clampFontScale`
    @property
    def poll_interval(self):
        return {"fast": 0.5, "lowPower": 3.0}.get(self.get("pollSpeed"), 1.0)

    @property
    def content_max_css(self):
        return {"narrow": "640px", "wide": "1100px", "full": "100%"}.get(
            self.get("contentWidth"), "860px"
        )

    def clamp_font_scale(self):
        self.set("fontScale", min(3.0, max(0.5, float(self.get("fontScale")))))

    def js_opts_json(self, custom_css):
        """The payload handed to JS applySettings(), PRD §3.2."""
        return json.dumps(
            {
                "theme": self.get("theme"),
                "contentWidth": self.get("contentWidth"),
                "contentMax": self.content_max_css,
                "mathEnabled": bool(self.get("mathEnabled")),
                "customCSS": custom_css,
            }
        )

    def custom_css_text(self):
        path = self.get("customCSSPath")
        if not path:
            return ""
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read()
        except (OSError, UnicodeDecodeError):
            return ""  # missing/bad → ignored, same as the Swift side


SETTINGS = Settings()


def apply_chrome_theme():
    """Match the GTK window chrome to the document theme.

    The web view themes itself from theme.css, but the header bar, sidebar and
    find bar are GTK widgets. Without this they keep the system theme, so a
    light document sits inside a dark window.
    """
    gtk_settings = Gtk.Settings.get_default()
    if gtk_settings is not None:
        gtk_settings.set_property("gtk-application-prefer-dark-theme",
                                  SETTINGS.get("theme") != "light")


# ---------------------------------------------------------------------------
# Per-file state, window frame + scroll memory (V11/V12)
# ---------------------------------------------------------------------------

class State:
    def __init__(self):
        self._d = {}
        try:
            with open(STATE_PATH, "r", encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                self._d = loaded
        except (OSError, ValueError):
            pass

    def save(self):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            tmp = STATE_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self._d, fh, indent=2)
            os.replace(tmp, STATE_PATH)
        except OSError:
            pass

    def for_file(self, path):
        entry = self._d.get("files", {}).get(path)
        return entry if isinstance(entry, dict) else {}

    def update_file(self, path, **kw):
        self._d.setdefault("files", {}).setdefault(path, {}).update(kw)
        self.save()

    @property
    def recents(self):
        r = self._d.get("recents", [])
        return [p for p in r if isinstance(p, str)] if isinstance(r, list) else []

    def push_recent(self, path):
        r = [p for p in self.recents if p != path]
        r.insert(0, path)
        self._d["recents"] = r[:10]
        self.save()

    def clear_recents(self):
        self._d["recents"] = []
        self.save()


STATE = State()


# ---------------------------------------------------------------------------
# mdlive-img:// scheme, port of ImageSchemeHandler (PRD §5.2 / DEC-13)
# ---------------------------------------------------------------------------

MIME_BY_EXT = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "svg": "image/svg+xml",
    "webp": "image/webp",
}


def mime_for_extension(ext):
    return MIME_BY_EXT.get(ext.lower(), "application/octet-stream")


def resolve_image(raw_url, doc_dir):
    """Percent-decode, canonicalize, require containment in doc_dir. None = reject.

    Pure function, mirroring ImageSchemeHandler.resolve so it is unit-testable
    without a webview (the Swift side made the same choice).
    """
    prefix = "mdlive-img://"
    if not raw_url.startswith(prefix) or not doc_dir:
        return None
    path = urllib.parse.unquote(raw_url[len(prefix):])
    if not path:
        return None
    canon = os.path.realpath(path)
    canon_dir = os.path.realpath(doc_dir)
    if canon != canon_dir and not canon.startswith(canon_dir + os.sep):
        return None
    return canon


class ImageScheme:
    """Serves mdlive-img:// for one webview. docDir is retargeted per render."""

    def __init__(self):
        self.doc_dir = None

    def handle(self, request):
        uri = request.get_uri()
        path = resolve_image(uri, self.doc_dir)
        if not path or not os.path.isfile(path):
            request.finish_error(
                GLib.Error.new_literal(
                    Gio.io_error_quark(), "mdlive: image rejected", Gio.IOErrorEnum.PERMISSION_DENIED
                )
            )
            return
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            request.finish_error(
                GLib.Error.new_literal(
                    Gio.io_error_quark(), "mdlive: unreadable", Gio.IOErrorEnum.NOT_FOUND
                )
            )
            return
        stream = Gio.MemoryInputStream.new_from_data(data)
        ext = os.path.splitext(path)[1].lstrip(".")
        request.finish(stream, len(data), mime_for_extension(ext))


# ---------------------------------------------------------------------------
# File watching, port of FileWatcher.swift (PRD §5.4 / DEC-7)
#   directory monitor + 150 ms debounce + (mtime,size)-stable guard
#   + poll fallback at Settings.pollInterval
# ---------------------------------------------------------------------------

DEBOUNCE_MS = 150


class FileWatcher:
    def __init__(self, path, on_changed, on_deleted, on_appeared):
        self.path = path
        self.on_changed = on_changed
        self.on_deleted = on_deleted
        self.on_appeared = on_appeared
        self._debounce_id = 0
        self._poll_id = 0
        self._monitor = None
        self._last_sig = self._signature()
        self._existed = os.path.exists(path)
        self._start()

    def _signature(self):
        try:
            st = os.stat(self.path)
            return (st.st_mtime, st.st_size)
        except OSError:
            return None

    def _start(self):
        # Monitor the PARENT directory, not the file: atomic replace (write temp
        # + rename) destroys the inode, which kills a file-level watch. This is
        # exactly why the Swift side watches the parent with FSEvents.
        try:
            d = Gio.File.new_for_path(os.path.dirname(self.path) or ".")
            self._monitor = d.monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
            self._monitor.connect("changed", self._on_monitor_event)
        except GLib.Error:
            self._monitor = None  # fall through to polling
        interval = max(1, int(SETTINGS.poll_interval * 1000))
        self._poll_id = GLib.timeout_add(interval, self._poll)

    def _on_monitor_event(self, _mon, file, other, _event):
        for f in (file, other):
            if f is not None and f.get_path() == self.path:
                self._schedule()
                return

    def _schedule(self):
        if self._debounce_id:
            GLib.source_remove(self._debounce_id)
        self._debounce_id = GLib.timeout_add(DEBOUNCE_MS, self._settle)

    def _settle(self):
        """Fire only once (mtime,size) has stopped moving, DEC-7 stability guard.

        Guards against reading a half-written file during a burst of writes.
        """
        self._debounce_id = 0
        sig = self._signature()
        exists = sig is not None
        if not exists:
            if self._existed:
                self._existed = False
                self._last_sig = None
                self.on_deleted()
            return False
        if sig != self._last_sig:
            self._last_sig = sig
            self._schedule()  # still moving, wait for it to settle
            return False
        if not self._existed:
            self._existed = True
            self.on_appeared()
        else:
            self.on_changed()
        return False

    def _poll(self):
        """1 s fallback for filesystems where the monitor is unreliable."""
        sig = self._signature()
        if sig != self._last_sig:
            self._schedule()
        return True

    def stop(self):
        if self._debounce_id:
            GLib.source_remove(self._debounce_id)
            self._debounce_id = 0
        if self._poll_id:
            GLib.source_remove(self._poll_id)
            self._poll_id = 0
        if self._monitor is not None:
            self._monitor.cancel()
            self._monitor = None


# ---------------------------------------------------------------------------
# Renderer, port of WebKitRenderer.swift
# ---------------------------------------------------------------------------

class Renderer:
    """Owns one WebView + the bundled shell. Renders queued before the `ready`
    handshake are flushed on ready (PRD §5.3)."""

    def __init__(self):
        self.images = ImageScheme()
        self.ucm = WebKit2.UserContentManager()
        for name in ("ready", "link", "outline", "scroll"):
            self.ucm.register_script_message_handler(name)
        self.ucm.connect("script-message-received::ready", self._on_ready_msg)
        self.ucm.connect("script-message-received::link", self._on_link_msg)
        self.ucm.connect("script-message-received::outline", self._on_outline_msg)
        self.ucm.connect("script-message-received::scroll", self._on_scroll_msg)

        self.webview = WebKit2.WebView.new_with_user_content_manager(self.ucm)
        # The webview uses the default WebContext; register mdlive-img there.
        # Registering the same scheme twice is harmless (last handler wins), so
        # this is safe with several windows open.
        ctx = self.webview.get_context()
        ctx.register_uri_scheme("mdlive-img", self._on_image_request)
        try:
            ctx.get_security_manager().register_uri_scheme_as_local("mdlive-img")
        except Exception:
            pass

        s = self.webview.get_settings()
        s.set_allow_file_access_from_file_urls(True)
        s.set_allow_universal_access_from_file_urls(True)
        s.set_enable_developer_extras(True)
        s.set_enable_write_console_messages_to_stdout(False)

        self.on_link = None
        self.on_ready = None
        self.on_outline = None
        self.on_scroll = None

        self._ready = False
        self._latest = None          # (markdown, base_dir, scroll_pct)
        self._did_first_render = False
        self.initial_scroll_pct = 0.0

    # -- scheme -------------------------------------------------------------
    def _on_image_request(self, request):
        self.images.handle(request)

    # -- shell --------------------------------------------------------------
    def load_shell(self):
        if not WEB_DIR:
            sys.stderr.write("MDLive: bundled web/ shell missing\n")
            return
        self.webview.load_uri("file://" + os.path.join(WEB_DIR, "index.html"))

    # -- render -------------------------------------------------------------
    def render(self, markdown, base_dir, scroll_pct=0.0):
        self._latest = (markdown, base_dir, scroll_pct)
        self.images.doc_dir = base_dir
        if self._ready:
            self._flush()

    def _flush(self):
        if not self._latest:
            return
        markdown, base_dir, scroll_pct = self._latest
        initial = not self._did_first_render
        pct = self.initial_scroll_pct if initial else scroll_pct
        self._did_first_render = True
        call = "render({}, {{baseDir: {}, scrollPct: {}, initial: {}}});".format(
            json.dumps(markdown), json.dumps(base_dir), float(pct),
            "true" if initial else "false",
        )
        self.eval(call)

        marker = os.environ.get("MDLIVE_GUI_MARKER")
        if marker:
            try:
                with open(marker, "a", encoding="utf-8") as fh:
                    fh.write("rendered {} chars baseDir={}\n".format(len(markdown), base_dir))
            except OSError:
                pass

    def apply_current_settings(self):
        if not self._ready:
            return
        self.eval("applySettings({});".format(SETTINGS.js_opts_json(SETTINGS.custom_css_text())))
        self.webview.set_zoom_level(min(3.0, max(0.5, float(SETTINGS.get("fontScale")))))
        apply_chrome_theme()

    # -- js plumbing --------------------------------------------------------
    def eval(self, script, callback=None):
        def done(wv, result, _u):
            value = None
            try:
                jsval = wv.evaluate_javascript_finish(result)
                if jsval is not None:
                    value = jsval.to_string()
            except GLib.Error:
                value = None
            if callback:
                callback(value)

        try:
            self.webview.evaluate_javascript(script, -1, None, None, None, done, None)
        except AttributeError:  # webkit2gtk < 2.40
            def legacy(wv, result, _u):
                value = None
                try:
                    js = wv.run_javascript_finish(result)
                    value = js.get_js_value().to_string()
                except GLib.Error:
                    value = None
                if callback:
                    callback(value)

            self.webview.run_javascript(script, None, legacy, None)

    @staticmethod
    def _msg_value(result):
        """script-message-received payload → python object."""
        try:
            val = result.get_js_value() if hasattr(result, "get_js_value") else result
        except Exception:
            val = result
        try:
            return json.loads(val.to_json(0))
        except Exception:
            try:
                return val.to_string()
            except Exception:
                return None

    def _on_ready_msg(self, _ucm, _res):
        self._ready = True
        self._flush()
        self.apply_current_settings()
        if self.on_ready:
            self.on_ready()

    def _on_link_msg(self, _ucm, res):
        href = self._msg_value(res)
        if isinstance(href, str) and self.on_link:
            self.on_link(href)

    def _on_outline_msg(self, _ucm, res):
        items = self._msg_value(res)
        if isinstance(items, list) and self.on_outline:
            self.on_outline([
                (int(d.get("level", 1)), str(d.get("text", "")), str(d.get("id", "")))
                for d in items
                if isinstance(d, dict) and d.get("id")
            ])

    def _on_scroll_msg(self, _ucm, res):
        pct = self._msg_value(res)
        try:
            pct = float(pct)
        except (TypeError, ValueError):
            return
        if self.on_scroll:
            self.on_scroll(pct)

    # -- find / outline / export -------------------------------------------
    def find(self, query, callback):
        self.eval("JSON.stringify(find(%s))" % json.dumps(query),
                  lambda v: callback(*decode_find(v or "")))

    def find_next(self, forward, callback):
        self.eval("JSON.stringify(findNext(%s))" % ("true" if forward else "false"),
                  lambda v: callback(*decode_find(v or "")))

    def clear_find(self):
        self.eval("clearFind()")

    def scroll_to_anchor(self, anchor):
        self.eval("scrollToAnchor(%s)" % json.dumps(anchor))

    def serialize_for_export(self, callback):
        self.eval("serializeForExport()", callback)

    def readback(self, callback):
        js = (
            "(function(){var c=document.getElementById('content');"
            "var html=c.innerHTML,text=c.innerText;"
            "var fr=(typeof find==='function')?find('e'):{count:0};"
            "if(typeof clearFind==='function')clearFind();"
            "var ser=(typeof serializeForExport==='function')?serializeForExport():'';"
            "return JSON.stringify({text:text,html:html,count:window.__mdliveRenderCount||0,"
            "theme:document.documentElement.getAttribute('data-theme'),"
            "contentMax:document.documentElement.style.getPropertyValue('--content-max'),"
            "math:!!window.__mathEnabled,"
            "userCSS:(document.getElementById('user-css')||{}).textContent||'',"
            "outlineLen:(window.__mdliveOutline||[]).length,findCount:fr.count,"
            "exportHasStyle:(ser.indexOf('<style>')>=0&&ser.indexOf('<h1')>=0),"
            "exportLen:ser.length});})()"
        )
        self.eval(js, callback)


def decode_find(js_json):
    """JSON from JS find()/findNext() → (count, current). Mirrors decodeFind."""
    try:
        d = json.loads(js_json)
        return int(d.get("count", 0)), int(d.get("current", 0))
    except (ValueError, TypeError, AttributeError):
        return 0, 0


# ---------------------------------------------------------------------------
# Document reading, PRD §5.5 error mapping
# ---------------------------------------------------------------------------

def read_markdown(path):
    """Return (text, error_string). Exactly one is non-None."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read(), None
    except FileNotFoundError:
        return None, ERR_MISSING.format(path=path)
    except IsADirectoryError:
        return None, ERR_MISSING.format(path=path)
    except PermissionError:
        return None, ERR_PERM.format(path=path)
    except UnicodeDecodeError:
        return None, ERR_ENCODING.format(path=path)
    except OSError:
        return None, ERR_MISSING.format(path=path)


# ---------------------------------------------------------------------------
# Document window, port of WindowManager.swift + DocumentView
# ---------------------------------------------------------------------------

class DocumentWindow(Gtk.ApplicationWindow):
    def __init__(self, app, path):
        super().__init__(application=app)
        self.app = app
        self.path = os.path.realpath(path)
        self.base_dir = os.path.dirname(self.path)
        self.watcher = None
        self.scroll_pct = 0.0
        self._outline_items = []
        self._last_good = None

        self.set_title(os.path.basename(self.path) + ", MDLive")
        saved = STATE.for_file(self.path)
        self.set_default_size(int(saved.get("w", 820)), int(saved.get("h", 720)))

        self.renderer = Renderer()
        self.renderer.initial_scroll_pct = float(saved.get("scroll", 0.0))
        self.renderer.on_link = self._on_link
        self.renderer.on_outline = self._on_outline
        self.renderer.on_scroll = self._on_scroll

        self._build_ui()
        self._build_actions()

        self.renderer.load_shell()
        self.reload(initial=True)
        self._start_watching()

        SETTINGS.subscribe(self._on_settings_changed)
        if SETTINGS.get("floatByDefault"):
            self.set_keep_above(True)

        self.connect("delete-event", self._on_close)
        STATE.push_recent(self.path)
        self.app.rebuild_recent_menu()

    # -- ui -----------------------------------------------------------------
    def _build_ui(self):
        header = Gtk.HeaderBar(show_close_button=True)
        header.set_title(os.path.basename(self.path))
        header.set_subtitle(self._pretty_dir())
        self.set_titlebar(header)
        self.header = header

        btn_open = Gtk.Button.new_from_icon_name("document-open-symbolic", Gtk.IconSize.BUTTON)
        btn_open.set_tooltip_text("Open…  (Ctrl+O)")
        btn_open.connect("clicked", lambda *_: self.app.action_open(self))
        header.pack_start(btn_open)

        self.btn_outline = Gtk.ToggleButton()
        self.btn_outline.set_image(
            Gtk.Image.new_from_icon_name("view-list-symbolic", Gtk.IconSize.BUTTON))
        self.btn_outline.set_tooltip_text("Outline  (Ctrl+Alt+1)")
        self.btn_outline.connect("toggled", self._on_outline_toggled)
        header.pack_start(self.btn_outline)

        menu_btn = Gtk.MenuButton()
        menu_btn.set_image(Gtk.Image.new_from_icon_name("open-menu-symbolic", Gtk.IconSize.BUTTON))
        menu_btn.set_popover(self._build_menu_popover())
        header.pack_end(menu_btn)

        btn_find = Gtk.Button.new_from_icon_name("edit-find-symbolic", Gtk.IconSize.BUTTON)
        btn_find.set_tooltip_text("Find  (Ctrl+F)")
        btn_find.connect("clicked", lambda *_: self.toggle_find(True))
        header.pack_end(btn_find)

        self.status = Gtk.Label(label="")
        self.status.get_style_context().add_class("dim-label")
        header.pack_end(self.status)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)

        # Find bar (V8)
        self.find_bar = Gtk.SearchBar()
        fb = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.find_entry = Gtk.SearchEntry()
        self.find_entry.set_width_chars(32)
        self.find_entry.connect("search-changed", self._on_find_changed)
        self.find_entry.connect("activate", lambda *_: self._step_find(True))
        self.find_entry.connect("stop-search", lambda *_: self.toggle_find(False))
        fb.pack_start(self.find_entry, False, False, 0)
        self.find_count = Gtk.Label(label="")
        self.find_count.get_style_context().add_class("dim-label")
        fb.pack_start(self.find_count, False, False, 0)
        b_prev = Gtk.Button.new_from_icon_name("go-up-symbolic", Gtk.IconSize.BUTTON)
        b_prev.connect("clicked", lambda *_: self._step_find(False))
        b_next = Gtk.Button.new_from_icon_name("go-down-symbolic", Gtk.IconSize.BUTTON)
        b_next.connect("clicked", lambda *_: self._step_find(True))
        fb.pack_start(b_prev, False, False, 0)
        fb.pack_start(b_next, False, False, 0)
        self.find_bar.add(fb)
        self.find_bar.connect_entry(self.find_entry)
        outer.pack_start(self.find_bar, False, False, 0)

        # Outline sidebar (V10) + webview
        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        self.paned = paned
        self.outline_scroll = Gtk.ScrolledWindow()
        self.outline_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.outline_list = Gtk.ListBox()
        self.outline_list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.outline_list.connect("row-activated", self._on_outline_row)
        self.outline_scroll.add(self.outline_list)
        self.outline_scroll.set_size_request(220, -1)
        paned.pack1(self.outline_scroll, False, False)

        self.stack = Gtk.Stack()
        self.stack.add_named(self.renderer.webview, "web")
        self.stack.add_named(self._build_error_view(), "error")
        paned.pack2(self.stack, True, False)
        outer.pack_start(paned, True, True, 0)

        self.show_all()
        self.outline_scroll.hide()  # collapsed until toggled

    def _pretty_dir(self):
        home = os.path.expanduser("~")
        d = self.base_dir
        return d.replace(home, "~", 1) if d.startswith(home) else d

    def _build_error_view(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        self.error_label = Gtk.Label(label="")
        self.error_label.set_justify(Gtk.Justification.CENTER)
        self.error_label.set_line_wrap(True)
        self.error_label.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.error_label.set_max_width_chars(60)
        self.error_label.set_selectable(True)
        box.pack_start(self.error_label, False, False, 0)
        btn = Gtk.Button(label=EMPTY_BUTTON)
        btn.set_halign(Gtk.Align.CENTER)
        btn.connect("clicked", lambda *_: self.app.action_open(self))
        box.pack_start(btn, False, False, 0)
        return box

    def _build_menu_popover(self):
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.set_border_width(8)

        def item(label, accel, cb):
            b = Gtk.Button(relief=Gtk.ReliefStyle.NONE)
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=18)
            lbl = Gtk.Label(label=label, xalign=0)
            row.pack_start(lbl, True, True, 0)
            if accel:
                a = Gtk.Label(label=accel, xalign=1)
                a.get_style_context().add_class("dim-label")
                row.pack_end(a, False, False, 0)
            b.add(row)
            b.connect("clicked", lambda *_: (pop.popdown(), cb()))
            box.pack_start(b, False, False, 0)

        def sep():
            box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 4)

        item("Refresh", "Ctrl+R", lambda: self.reload())
        item("Copy File Path", "Ctrl+L", self.copy_path)
        item("Open Containing Folder", "Ctrl+Shift+R", self.reveal)
        sep()
        item("Zoom In", "Ctrl++", lambda: self.zoom(0.1))
        item("Zoom Out", "Ctrl+-", lambda: self.zoom(-0.1))
        item("Actual Size", "Ctrl+0", lambda: self.zoom(None))
        sep()
        item("Toggle Theme", None, self.toggle_theme)
        item("Keep on Top", "Ctrl+Shift+T", self.toggle_on_top)
        sep()
        item("Print…", "Ctrl+P", self.do_print)
        item("Export HTML…", None, self.export_html)
        item("Export PDF…", None, self.export_pdf)
        sep()
        item("Settings…", "Ctrl+,", lambda: SettingsWindow(self.app, self).present())
        item("Help", None, self.app.action_help)

        box.show_all()
        pop.add(box)
        return pop

    # -- actions / accelerators --------------------------------------------
    def _build_actions(self):
        """Command-key accelerators from Shortcuts.swift, remapped to Control."""
        accels = [
            ("<Primary>r", lambda: self.reload()),
            ("<Primary>f", lambda: self.toggle_find(True)),
            ("<Primary>g", lambda: self._step_find(True)),
            ("<Primary><Shift>g", lambda: self._step_find(False)),
            ("<Primary>l", self.copy_path),
            ("<Primary><Shift>r", self.reveal),
            ("<Primary>p", self.do_print),
            ("<Primary>equal", lambda: self.zoom(0.1)),
            ("<Primary>plus", lambda: self.zoom(0.1)),
            ("<Primary>KP_Add", lambda: self.zoom(0.1)),
            ("<Primary>minus", lambda: self.zoom(-0.1)),
            ("<Primary>KP_Subtract", lambda: self.zoom(-0.1)),
            ("<Primary>0", lambda: self.zoom(None)),
            ("<Primary><Alt>1", lambda: self.btn_outline.set_active(
                not self.btn_outline.get_active())),
            ("<Primary><Shift>t", self.toggle_on_top),
            ("<Primary>o", lambda: self.app.action_open(self)),
            ("<Primary>w", lambda: self.close()),
            ("<Primary>comma", lambda: SettingsWindow(self.app, self).present()),
            ("Escape", lambda: self.toggle_find(False)),
        ]
        group = Gtk.AccelGroup()
        self.add_accel_group(group)
        for spec, fn in accels:
            key, mods = Gtk.accelerator_parse(spec)
            if key:
                group.connect(key, mods, Gtk.AccelFlags.VISIBLE,
                              lambda *a, _f=fn: (_f(), True)[1])

    # -- document lifecycle -------------------------------------------------
    def reload(self, initial=False):
        text, err = read_markdown(self.path)
        if err:
            # Keep the last good render if we have one; show the error either way.
            self.error_label.set_text(err)
            self.stack.set_visible_child_name("error")
            return
        self._last_good = text
        self.stack.set_visible_child_name("web")
        self.renderer.render(text, self.base_dir, self.scroll_pct)
        if not initial:
            self._flash_status("Reloading…")

    def _flash_status(self, msg):
        self.status.set_text(msg)
        GLib.timeout_add(700, lambda: (self.status.set_text(""), False)[1])

    def _start_watching(self):
        if self.watcher:
            self.watcher.stop()
        if not SETTINGS.get("autoRefresh"):
            self.watcher = None
            return
        self.watcher = FileWatcher(
            self.path,
            on_changed=lambda: self.reload(),
            on_deleted=self._on_deleted,
            on_appeared=lambda: self.reload(),
        )

    def _on_deleted(self):
        # PRD §5.4: error state, but keep watching the directory for recovery.
        self.error_label.set_text(ERR_MISSING.format(path=self.path))
        self.stack.set_visible_child_name("error")

    def _on_settings_changed(self):
        self.renderer.apply_current_settings()
        self._start_watching()

    def _on_close(self, *_):
        w, h = self.get_size()
        STATE.update_file(self.path, w=w, h=h, scroll=self.scroll_pct)
        if self.watcher:
            self.watcher.stop()
            self.watcher = None
        self.app.forget_window(self.path)
        return False

    # -- callbacks from JS --------------------------------------------------
    def _on_scroll(self, pct):
        self.scroll_pct = pct

    def _on_link(self, href):
        """DEC-11 link routing: .md opens in MDLive, everything else to the OS."""
        low = href.lower()
        if low.startswith("#"):
            self.renderer.scroll_to_anchor(href[1:])
            return
        if low.startswith(("http://", "https://", "mailto:")):
            Gtk.show_uri_on_window(self, href, Gdk.CURRENT_TIME)
            return
        target = href if os.path.isabs(href) else os.path.join(self.base_dir, href)
        target = os.path.realpath(target)
        if os.path.isfile(target) and target.lower().endswith(MD_SUFFIXES):
            self.app.open_path(target)
        elif os.path.exists(target):
            Gtk.show_uri_on_window(self, "file://" + urllib.parse.quote(target), Gdk.CURRENT_TIME)

    def _on_outline(self, items):
        self._outline_items = items
        for child in self.outline_list.get_children():
            self.outline_list.remove(child)
        for level, text, anchor in items:
            row = Gtk.ListBoxRow()
            lbl = Gtk.Label(label=text, xalign=0)
            lbl.set_ellipsize(Pango.EllipsizeMode.END)
            lbl.set_margin_top(3)
            lbl.set_margin_bottom(3)
            lbl.set_margin_start(6 + (level - 1) * 12)
            lbl.set_margin_end(6)
            if level == 1:
                lbl.set_markup("<b>%s</b>" % GLib.markup_escape_text(text))
            row.add(lbl)
            row.anchor = anchor
            self.outline_list.add(row)
        self.outline_list.show_all()

    def _on_outline_row(self, _list, row):
        anchor = getattr(row, "anchor", None)
        if anchor:
            self.renderer.scroll_to_anchor(anchor)

    def _on_outline_toggled(self, btn):
        if btn.get_active():
            self.outline_scroll.show()
            self.paned.set_position(240)
        else:
            self.outline_scroll.hide()

    # -- find ---------------------------------------------------------------
    def toggle_find(self, on):
        self.find_bar.set_search_mode(on)
        if on:
            self.find_entry.grab_focus()
        else:
            self.renderer.clear_find()
            self.find_count.set_text("")

    def _on_find_changed(self, entry):
        q = entry.get_text()
        if not q:
            self.renderer.clear_find()
            self.find_count.set_text("")
            return
        self.renderer.find(q, self._show_find_count)

    def _step_find(self, forward):
        if not self.find_bar.get_search_mode():
            self.toggle_find(True)
            return
        self.renderer.find_next(forward, self._show_find_count)

    def _show_find_count(self, count, current):
        self.find_count.set_text("No results" if count == 0 else "%d of %d" % (current, count))

    # -- commands -----------------------------------------------------------
    def zoom(self, delta):
        if delta is None:
            SETTINGS.set("fontScale", 1.0)
        else:
            SETTINGS.set("fontScale", min(3.0, max(0.5, float(SETTINGS.get("fontScale")) + delta)))

    def toggle_theme(self):
        SETTINGS.set("theme", "light" if SETTINGS.get("theme") == "dark" else "dark")

    def toggle_on_top(self):
        self._on_top = not getattr(self, "_on_top", SETTINGS.get("floatByDefault"))
        self.set_keep_above(self._on_top)
        self._flash_status("On top" if self._on_top else "Not on top")

    def copy_path(self):
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(self.path, -1)
        self._flash_status("Path copied")

    def reveal(self):
        Gtk.show_uri_on_window(self, "file://" + urllib.parse.quote(self.base_dir), Gdk.CURRENT_TIME)

    def do_print(self):
        op = WebKit2.PrintOperation.new(self.renderer.webview)
        op.run_dialog(self)

    def _save_dialog(self, title, default_name, pattern_name, pattern):
        dlg = Gtk.FileChooserDialog(title=title, transient_for=self,
                                    action=Gtk.FileChooserAction.SAVE)
        dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                        Gtk.STOCK_SAVE, Gtk.ResponseType.ACCEPT)
        dlg.set_do_overwrite_confirmation(True)
        dlg.set_current_name(default_name)
        f = Gtk.FileFilter()
        f.set_name(pattern_name)
        f.add_pattern(pattern)
        dlg.add_filter(f)
        path = dlg.get_filename() if dlg.run() == Gtk.ResponseType.ACCEPT else None
        dlg.destroy()
        return path

    def export_html(self):
        stem = os.path.splitext(os.path.basename(self.path))[0]
        out = self._save_dialog("Export HTML", stem + ".html", "HTML", "*.html")
        if not out:
            return

        def write(html):
            if not html:
                return
            try:
                with open(out, "w", encoding="utf-8") as fh:
                    fh.write(html)
                self._flash_status("Exported")
            except OSError as e:
                self._flash_status("Export failed: %s" % e)

        self.renderer.serialize_for_export(write)

    def export_pdf(self):
        stem = os.path.splitext(os.path.basename(self.path))[0]
        out = self._save_dialog("Export PDF", stem + ".pdf", "PDF", "*.pdf")
        if not out:
            return
        op = WebKit2.PrintOperation.new(self.renderer.webview)
        settings = Gtk.PrintSettings()
        settings.set(Gtk.PRINT_SETTINGS_OUTPUT_URI, "file://" + urllib.parse.quote(out))
        settings.set(Gtk.PRINT_SETTINGS_OUTPUT_FILE_FORMAT, "pdf")
        op.set_print_settings(settings)
        op.connect("finished", lambda *_: self._flash_status("Exported PDF"))
        op.print_()


# ---------------------------------------------------------------------------
# Settings window, port of SettingsView.swift
# ---------------------------------------------------------------------------

class SettingsWindow(Gtk.Window):
    def __init__(self, app, parent):
        super().__init__(title="MDLive Settings", transient_for=parent)
        self.app = app
        self.set_default_size(460, 460)
        self.set_border_width(16)

        grid = Gtk.Grid(row_spacing=10, column_spacing=14)
        self.add(grid)
        r = 0

        def label(text):
            l = Gtk.Label(label=text, xalign=0)
            return l

        # Theme
        grid.attach(label("Theme"), 0, r, 1, 1)
        theme = Gtk.ComboBoxText()
        for v in ("dark", "light"):
            theme.append(v, v.capitalize())
        theme.set_active_id(SETTINGS.get("theme"))
        theme.connect("changed", lambda c: SETTINGS.set("theme", c.get_active_id()))
        grid.attach(theme, 1, r, 1, 1)
        r += 1

        # Content width
        grid.attach(label("Content width"), 0, r, 1, 1)
        width = Gtk.ComboBoxText()
        for v, t in (("narrow", "Narrow"), ("medium", "Medium"),
                     ("wide", "Wide"), ("full", "Full")):
            width.append(v, t)
        width.set_active_id(SETTINGS.get("contentWidth"))
        width.connect("changed", lambda c: SETTINGS.set("contentWidth", c.get_active_id()))
        grid.attach(width, 1, r, 1, 1)
        r += 1

        # Font scale
        grid.attach(label("Font scale"), 0, r, 1, 1)
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0.5, 3.0, 0.05)
        scale.set_value(float(SETTINGS.get("fontScale")))
        scale.set_hexpand(True)
        scale.set_digits(2)
        scale.connect("value-changed", lambda s: SETTINGS.set("fontScale", round(s.get_value(), 2)))
        grid.attach(scale, 1, r, 1, 1)
        r += 1

        # Auto refresh
        auto = Gtk.CheckButton(label="Auto-refresh when the file changes")
        auto.set_active(bool(SETTINGS.get("autoRefresh")))
        auto.connect("toggled", lambda c: SETTINGS.set("autoRefresh", c.get_active()))
        grid.attach(auto, 0, r, 2, 1)
        r += 1

        # Poll speed
        grid.attach(label("Watch speed"), 0, r, 1, 1)
        poll = Gtk.ComboBoxText()
        for v, t in (("fast", "Fast (0.5 s)"), ("normal", "Normal (1 s)"),
                     ("lowPower", "Low power (3 s)")):
            poll.append(v, t)
        poll.set_active_id(SETTINGS.get("pollSpeed"))
        poll.connect("changed", lambda c: SETTINGS.set("pollSpeed", c.get_active_id()))
        grid.attach(poll, 1, r, 1, 1)
        r += 1

        # Math
        math = Gtk.CheckButton(label="Render LaTeX math (KaTeX)")
        math.set_active(bool(SETTINGS.get("mathEnabled")))
        math.connect("toggled", lambda c: SETTINGS.set("mathEnabled", c.get_active()))
        grid.attach(math, 0, r, 2, 1)
        r += 1

        # Float by default
        float_top = Gtk.CheckButton(label="New windows stay on top")
        float_top.set_active(bool(SETTINGS.get("floatByDefault")))
        float_top.connect("toggled", lambda c: SETTINGS.set("floatByDefault", c.get_active()))
        grid.attach(float_top, 0, r, 2, 1)
        r += 1

        # Custom CSS
        grid.attach(label("Custom CSS"), 0, r, 1, 1)
        css_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        css_entry = Gtk.Entry()
        css_entry.set_text(SETTINGS.get("customCSSPath"))
        css_entry.set_hexpand(True)
        css_entry.connect("changed", lambda e: SETTINGS.set("customCSSPath", e.get_text()))
        pick = Gtk.Button(label="Choose…")

        def choose(_b):
            dlg = Gtk.FileChooserDialog(title="Choose CSS", transient_for=self,
                                        action=Gtk.FileChooserAction.OPEN)
            dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                            Gtk.STOCK_OPEN, Gtk.ResponseType.ACCEPT)
            if dlg.run() == Gtk.ResponseType.ACCEPT:
                css_entry.set_text(dlg.get_filename())
            dlg.destroy()

        pick.connect("clicked", choose)
        css_box.pack_start(css_entry, True, True, 0)
        css_box.pack_start(pick, False, False, 0)
        grid.attach(css_box, 1, r, 1, 1)
        r += 1

        # Restore defaults
        restore = Gtk.Button(label="Restore Defaults")
        restore.set_halign(Gtk.Align.END)

        def do_restore(_b):
            SETTINGS.restore_defaults()
            theme.set_active_id(SETTINGS.get("theme"))
            width.set_active_id(SETTINGS.get("contentWidth"))
            scale.set_value(float(SETTINGS.get("fontScale")))
            auto.set_active(bool(SETTINGS.get("autoRefresh")))
            poll.set_active_id(SETTINGS.get("pollSpeed"))
            math.set_active(bool(SETTINGS.get("mathEnabled")))
            float_top.set_active(bool(SETTINGS.get("floatByDefault")))
            css_entry.set_text("")

        restore.connect("clicked", do_restore)
        grid.attach(restore, 1, r, 1, 1)

        self.show_all()


# ---------------------------------------------------------------------------
# Application, port of MDLiveApp.swift + WindowManager
# ---------------------------------------------------------------------------

class MDLiveApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID,
                         flags=Gio.ApplicationFlags.HANDLES_OPEN)
        self.windows_by_path = {}

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.rebuild_recent_menu()

    def do_activate(self):
        # No file given, show the empty state (PRD §5.5).
        if not self.windows_by_path:
            EmptyWindow(self).present()

    def do_open(self, files, n_files, _hint):
        for f in files[:n_files]:
            p = f.get_path()
            if p:
                self.open_path(p)
        if not self.windows_by_path:
            self.do_activate()

    def open_path(self, path):
        """One window per file, deduped, re-open focuses (WindowManager.swift)."""
        real = os.path.realpath(path)
        win = self.windows_by_path.get(real)
        if win is not None:
            win.present()
            return win
        win = DocumentWindow(self, real)
        self.windows_by_path[real] = win
        win.present()
        return win

    def forget_window(self, path):
        self.windows_by_path.pop(os.path.realpath(path), None)

    def rebuild_recent_menu(self):
        pass  # recents live in the file chooser + Open dialog

    def action_open(self, parent):
        dlg = Gtk.FileChooserDialog(title="Open Markdown File", transient_for=parent,
                                    action=Gtk.FileChooserAction.OPEN)
        dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                        Gtk.STOCK_OPEN, Gtk.ResponseType.ACCEPT)
        f = Gtk.FileFilter()
        f.set_name("Markdown")
        for suf in MD_SUFFIXES:
            f.add_pattern("*" + suf)
        dlg.add_filter(f)
        allf = Gtk.FileFilter()
        allf.set_name("All files")
        allf.add_pattern("*")
        dlg.add_filter(allf)
        path = dlg.get_filename() if dlg.run() == Gtk.ResponseType.ACCEPT else None
        dlg.destroy()
        if path:
            self.open_path(path)
            if isinstance(parent, EmptyWindow):
                parent.destroy()

    def action_help(self):
        if WEB_DIR:
            help_md = os.path.join(WEB_DIR, "Help.md")
            if os.path.isfile(help_md):
                self.open_path(help_md)


class EmptyWindow(Gtk.ApplicationWindow):
    """PRD §5.5 empty state, shown when MDLive is launched with no file."""

    def __init__(self, app):
        super().__init__(application=app, title="MDLive")
        self.app = app
        self.set_default_size(560, 360)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        title = Gtk.Label()
        title.set_markup("<span size='xx-large' weight='bold'>%s</span>"
                         % GLib.markup_escape_text(EMPTY_TITLE))
        body = Gtk.Label(label=EMPTY_BODY)
        body.set_line_wrap(True)
        body.set_max_width_chars(48)
        body.set_justify(Gtk.Justification.CENTER)
        body.get_style_context().add_class("dim-label")
        btn = Gtk.Button(label=EMPTY_BUTTON)
        btn.set_halign(Gtk.Align.CENTER)
        btn.connect("clicked", lambda *_: self.app.action_open(self))
        box.pack_start(title, False, False, 0)
        box.pack_start(body, False, False, 0)
        box.pack_start(btn, False, False, 0)
        self.add(box)
        self.show_all()


# ---------------------------------------------------------------------------
# Selftest, headless DOM readback, the Linux twin of SelfTestRunner.swift
# ---------------------------------------------------------------------------

def run_selftest():
    """Render fixtures offscreen and assert on the real DOM. Exit 0 = pass."""
    import tempfile

    failures = []
    checks = []

    def check(name, ok, detail=""):
        checks.append((name, ok, detail))
        if not ok:
            failures.append("%s %s" % (name, detail))

    # --- pure-function checks (no webview needed) ---
    check("mime.png", mime_for_extension("png") == "image/png")
    check("mime.unknown", mime_for_extension("xyz") == "application/octet-stream")
    check("decodeFind.ok", decode_find('{"count":3,"current":1}') == (3, 1))
    check("decodeFind.garbage", decode_find("not json") == (0, 0))

    tmpd = tempfile.mkdtemp(prefix="mdlive-selftest-")
    inside = os.path.join(tmpd, "img.png")
    open(inside, "wb").close()
    check("img.inside", resolve_image(
        "mdlive-img://" + urllib.parse.quote(inside), tmpd) == os.path.realpath(inside))
    check("img.escape", resolve_image(
        "mdlive-img://" + urllib.parse.quote("/etc/passwd"), tmpd) is None,
        "path outside doc dir must be rejected")
    check("img.nodir", resolve_image("mdlive-img://" + urllib.parse.quote(inside), None) is None)

    check("settings.contentMax", SETTINGS.content_max_css in
          ("640px", "860px", "1100px", "100%"))
    check("web.dir", WEB_DIR is not None and
          os.path.isfile(os.path.join(WEB_DIR or "", "index.html")),
          "Resources/web/index.html not found")

    # error copy
    _, err = read_markdown(os.path.join(tmpd, "does-not-exist.md"))
    check("err.missing", err is not None and err.startswith("Can't find this file"), repr(err))

    if not WEB_DIR:
        _report(checks, failures)
        return 1 if failures else 0

    # --- live render check in a real (offscreen) webview ---
    fixture = os.path.join(tmpd, "hello.md")
    with open(fixture, "w", encoding="utf-8") as fh:
        fh.write("# Hello, MDLive\n\n"
                 "Some **bold** text.\n\n"
                 "```python\ndef f():\n    return 1\n```\n\n"
                 "> a quote\n\n"
                 "| a | b |\n|---|---|\n| 1 | 2 |\n\n"
                 "## Second heading\n")

    result = {}
    renderer = Renderer()
    win = Gtk.OffscreenWindow()
    win.add(renderer.webview)
    win.show_all()

    def on_readback(value):
        result["raw"] = value
        Gtk.main_quit()

    def on_ready():
        GLib.timeout_add(600, lambda: (renderer.readback(on_readback), False)[1])

    renderer.on_ready = on_ready
    renderer.load_shell()
    text, _ = read_markdown(fixture)
    renderer.render(text, tmpd, 0.0)

    GLib.timeout_add(15000, lambda: (Gtk.main_quit(), False)[1])  # hard cap
    Gtk.main()

    raw = result.get("raw")
    check("render.readback", bool(raw), "no DOM readback (webview never reported)")
    if raw:
        try:
            d = json.loads(raw)
        except ValueError:
            d = {}
        check("render.h1", "<h1" in d.get("html", "") and "Hello, MDLive" in d.get("text", ""))
        check("render.bold", "<strong>" in d.get("html", ""))
        check("render.hljs", "hljs-keyword" in d.get("html", "") or "hljs" in d.get("html", ""),
              "syntax highlighting did not run")
        check("render.blockquote", "<blockquote>" in d.get("html", ""))
        check("render.table", "<table>" in d.get("html", ""))
        check("render.count", int(d.get("count", 0)) >= 1)
        check("render.theme", d.get("theme") in ("dark", "light"))
        check("render.outline", int(d.get("outlineLen", 0)) >= 2,
              "outline saw %s headings" % d.get("outlineLen"))
        check("render.find", int(d.get("findCount", 0)) >= 1)
        check("render.export", bool(d.get("exportHasStyle")))

    _report(checks, failures)
    return 1 if failures else 0


def _report(checks, failures):
    width = max(len(n) for n, _, _ in checks) + 2
    for name, ok, detail in checks:
        # Detail is the failure hint, so only show it when the check failed.
        sys.stdout.write("  %s %-*s %s\n"
                         % ("PASS" if ok else "FAIL", width, name, "" if ok else detail))
    sys.stdout.write("\n%d checks, %d failed\n" % (len(checks), len(failures)))
    sys.stdout.write("SELFTEST %s\n" % ("PASS" if not failures else "FAIL"))


# ---------------------------------------------------------------------------

def main(argv):
    if "--selftest" in argv:
        return run_selftest()
    if "--version" in argv:
        sys.stdout.write("MDLive (Linux port), web assets from MDLive/Resources/web\n")
        return 0
    app = MDLiveApp()
    return app.run(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
