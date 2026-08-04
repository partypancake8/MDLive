#!/usr/bin/env bash
# Install MDLive (Linux) into ~/.local. No root needed.
#
#   ./install.sh              install, and set MDLive as the default .md opener
#   ./install.sh --no-default install without touching your default handler
#   ./install.sh --uninstall  remove it again
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/.local/bin/mdlive"
APPS="$HOME/.local/share/applications"
DESKTOP="$APPS/mdlive.desktop"
SHARE="$HOME/.local/share/mdlive"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"

if [ "$1" = "--uninstall" ]; then
  rm -f "$BIN" "$DESKTOP" "$ICONS/mdlive.svg"
  rm -rf "$SHARE"
  update-desktop-database "$APPS" 2>/dev/null || true
  echo "DONE: MDLive removed. Your default .md handler was left alone."
  exit 0
fi

echo "Checking dependencies..."
python3 - <<'PY'
import sys
try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.1")
    from gi.repository import Gtk, WebKit2  # noqa: F401
except Exception as e:
    sys.stderr.write(
        "\nMissing GTK/WebKit bindings: %s\n"
        "Install them with:\n"
        "  sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1\n\n" % e)
    sys.exit(1)
PY
echo "  ok: python3-gi + GTK3 + WebKit2GTK 4.1"

mkdir -p "$HOME/.local/bin" "$APPS" "$SHARE" "$ICONS"

# Copy the web assets so the install does not depend on the checkout staying put.
rm -rf "$SHARE/web"
cp -R "$REPO/MDLive/Resources/web" "$SHARE/web"
cp "$REPO/linux/mdlive.py" "$SHARE/mdlive.py"
chmod +x "$SHARE/mdlive.py"

cat > "$BIN" <<EOF
#!/usr/bin/env bash
exec python3 "$SHARE/mdlive.py" "\$@"
EOF
chmod +x "$BIN"

# Icon: the macOS app ships .icns, which Linux icon themes cannot read, so draw
# the same dark "M v" mark as an SVG.
cat > "$ICONS/mdlive.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">
  <rect width="128" height="128" rx="26" fill="#16181d"/>
  <rect x="1.5" y="1.5" width="125" height="125" rx="24.5" fill="none" stroke="#2b2f38" stroke-width="3"/>
  <path d="M28 88V40h11l17 26 17-26h11v48H72V60L56 84 40 60v28z" fill="#e6e8ee"/>
  <path d="M52 96l12 14 12-14" fill="none" stroke="#6ea8fe" stroke-width="8"
        stroke-linecap="round" stroke-linejoin="round"/>
</svg>
EOF

sed "s|^Exec=.*|Exec=$BIN %F|" "$REPO/linux/mdlive.desktop" > "$DESKTOP"
chmod +x "$DESKTOP"

update-desktop-database "$APPS" 2>/dev/null || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

if [ "$1" != "--no-default" ]; then
  PREV="$(xdg-mime query default text/markdown 2>/dev/null || true)"
  [ -n "$PREV" ] && echo "  previous default was: $PREV"
  xdg-mime default mdlive.desktop text/markdown text/x-markdown
  echo "  default .md opener is now: $(xdg-mime query default text/markdown)"
fi

echo
echo "Installed:"
echo "  binary   $BIN"
echo "  desktop  $DESKTOP"
echo "  assets   $SHARE/web"
echo
echo "Try it:   mdlive $REPO/sample/kitchen-sink.md"
echo "Selftest: mdlive --selftest"
echo "DONE"
