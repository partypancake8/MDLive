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
    ("four valid mermaid fences render an <svg>", d.get("mermaidSvg") == 4),
    ("the broken fence shows the error line", d.get("mermaidErrors") == 1 and "Mermaid error:" in d.get("text", "")),
    ("the broken fence keeps its source", "this is not valid mermaid" in d.get("text", "")),
    ("only the broken fence is still a language-mermaid code block", d.get("html", "").count('class="language-mermaid"') == 1),
    ("mermaid rendering settled before readback", d.get("mermaidBusy") is False),
    ("ordinary code is still highlighted", "hljs-" in d.get("html", "")),
]
# Sizing (Mermaid Live Editor practice, useMaxWidth off): every SVG keeps its natural
# pixel width (no width="100%"), text is the page's 16px, a narrow diagram stays
# narrower than its host, and the wide sequence overflows its host (scrolls) with a
# "Fit width" toggle offered only there.
m = [x for x in d.get("mermaidMetrics", []) if x]
seq = m[1] if len(m) > 1 else {}
wide = m[3] if len(m) > 3 else {}
checks += [
    ("metrics reported for every rendered svg", len(m) == 4),
    ("no svg is width=100% (natural size)", all(x.get("widthAttr") != "100%" for x in m)),
    ("sequence message text is the page's 16px", seq.get("textFontSize") == "16px"),
    ("narrow sequence is not stretched past its natural width", 0 < seq.get("svgWidth", 0) < seq.get("containerWidth", 0)),
    ("wide sequence is wider than its host, so it scrolls", wide.get("svgWidth", 0) > wide.get("containerWidth", 0) and wide.get("scrollWidth", 0) > wide.get("containerWidth", 0)),
    ("wide sequence message text is >= 14px", float(str(wide.get("textFontSize", "0px")).replace("px", "")) >= 14),
    ("Fit width toggle only on the wide diagram", wide.get("fitToggle") is True and seq.get("fitToggle") is False),
]
fails = 0
for name, ok in checks:
    print(("PASS  " if ok else "FAIL  ") + name)
    fails += 0 if ok else 1
print("\n%d checks, %d failed" % (len(checks), fails))
sys.exit(1 if fails else 0)
PY
