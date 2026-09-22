#!/usr/bin/env bash
# Web-side test: render sample/mermaid.md headlessly through the app's own
# self-test harness (MDLIVE_SELFTEST, real WKWebView, no window shown) and
# assert on the DOM that comes back. Exit 0 = pass.
#
#   web-tests/mermaid-test.sh                     # uses /Applications/MDLive.app
#   MDLIVE_APP=build/dd/Build/Products/Release/MDLive.app web-tests/mermaid-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${MDLIVE_APP:-/Applications/MDLive.app}"
BIN="$APP/Contents/MacOS/MDLive"
[[ -x "$BIN" ]] || { echo "FAIL: no MDLive binary at $BIN" >&2; exit 1; }
OUT="$(mktemp -t mdlive-mermaid).json"
MDLIVE_SELFTEST="$OUT" MDLIVE_OPEN="$PWD/sample/mermaid.md" "$BIN" || { echo "FAIL: selftest exit $?" >&2; exit 1; }
python3 - "$OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
checks = [
    ("three valid mermaid fences render an <svg>", d.get("mermaidSvg") == 3),
    ("the broken fence shows the error line", d.get("mermaidErrors") == 1 and "Mermaid error:" in d.get("text", "")),
    ("the broken fence keeps its source", "this is not valid mermaid" in d.get("text", "")),
    ("only the broken fence is still a language-mermaid code block", d.get("html", "").count('class="language-mermaid"') == 1),
    ("mermaid rendering settled before readback", d.get("mermaidBusy") is False),
    ("ordinary code is still highlighted", "hljs-" in d.get("html", "")),
]
fails = 0
for name, ok in checks:
    print(("PASS  " if ok else "FAIL  ") + name)
    fails += 0 if ok else 1
print("\n%d checks, %d failed" % (len(checks), fails))
sys.exit(1 if fails else 0)
PY
