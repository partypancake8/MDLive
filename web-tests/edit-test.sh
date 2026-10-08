#!/usr/bin/env bash
# Web-side test for in-place editing: open sample/kitchen-sink.md headlessly
# through the app's edit gate (MDLIVE_EDIT_SELFTEST, real WKWebView, no window),
# type into one block through the page's own editing path, let autosave write
# the file, and assert the saved Markdown differs from the original only in the
# expected source lines. Exit 0 = pass.
#
#   web-tests/edit-test.sh                     # uses /Applications/MDLive.app
#   MDLIVE_APP=build/dd/Build/Products/Debug/MDLive.app web-tests/edit-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${MDLIVE_APP:-/Applications/MDLive.app}"
BIN="$APP/Contents/MacOS/MDLive"
[[ -x "$BIN" ]] || { echo "FAIL: no MDLive binary at $BIN" >&2; exit 1; }
SRC="$PWD/sample/kitchen-sink.md"
WORK="$(mktemp -d -t mdlive-edit)"
fails=0

# case <name> <css selector> <text or ""> <python check over (orig, new) line lists>
run_case() {
  local name="$1" sel="$2" text="$3" check="$4" d="$WORK/$1"
  mkdir -p "$d"; cp "$SRC" "$d/doc.md"; cp -R sample/assets "$d/"
  touch -t 202001010000 "$d/doc.md"
  local rc=0
  if [[ -n "$text" ]]; then
    MDLIVE_EDIT_SELFTEST="$d/out.json" MDLIVE_OPEN="$d/doc.md" MDLIVE_EDIT_SELECTOR="$sel" MDLIVE_EDIT_TEXT="$text" "$BIN" >/dev/null 2>&1 || rc=$?
  else
    MDLIVE_EDIT_SELFTEST="$d/out.json" MDLIVE_OPEN="$d/doc.md" MDLIVE_EDIT_SELECTOR="$sel" "$BIN" >/dev/null 2>&1 || rc=$?
  fi
  if python3 -I - "$SRC" "$d/doc.md" "$d/out.json" "$rc" "$check" <<'PY'
import difflib, json, os, sys
src, new, out, rc, check = sys.argv[1:6]
O = open(src).read().split("\n"); N = open(new).read().split("\n")
info = json.load(open(out)) if os.path.exists(out) else {}
changed = [l for l in difflib.unified_diff(O, N, lineterm="", n=0) if l[:1] in "+-" and l[:3] not in ("+++", "---")]
removed = [l[1:] for l in changed if l[0] == "-"]; added = [l[1:] for l in changed if l[0] == "+"]
mtime_untouched = abs(os.stat(new).st_mtime - __import__("time").mktime((2020, 1, 1, 0, 0, 0, 0, 0, -1))) < 1
ok = int(rc) == 0 and eval(check)
if not ok:
    print("   rc=%s info=%s" % (rc, info)); print("   " + "\n   ".join(changed) if changed else "   (no diff)")
sys.exit(0 if ok else 1)
PY
  then echo "PASS  $name"; else echo "FAIL  $name"; fails=$((fails + 1)); fi
}

T=' zebra-edit-token'
run_case "paragraph edit changes only that line" "p" "$T" \
  'removed == ["A paragraph with **bold**, *italic*, `inline code`, ~~strikethrough~~, and a [link](https://example.com)."] and added == [removed[0] + "'"$T"'"] and info.get("saveCount") == 1'
run_case "list item edit changes only that item" "li" "$T" \
  'removed == ["- bullet one"] and added == ["- bullet one'"$T"'"]'
run_case "task item keeps its checkbox" "ul.contains-task-list li:nth-child(2)" "$T" \
  'removed == ["- [x] task done"] and added == ["- [x] task done'"$T"'"]'
run_case "code block line edit keeps the fence and language" "pre code" "_v2" \
  'removed == ["    return f\"hello, {name}\""] and added == ["    return f\"hello, {name}\"_v2"] and "```python" in N'
run_case "table cell edit changes only that row" "td" "$T" \
  'len(removed) == 1 and removed[0].startswith("| 1 ") and len(added) == 1 and "'"$T"'" in added[0] and "|----------|----------|" in N and "| three    | four     |" in N'
run_case "heading edit keeps its level" "h2" "$T" \
  'removed == ["## Heading 2"] and added == ["## Heading 2'"$T"'"]'
run_case "footnote body keeps its label" "section.footnotes p" "$T" \
  'removed == ["[^1]: And here is the footnote body."] and added == ["[^1]: And here is the footnote body.'"$T"'"]'
run_case "Enter after a paragraph adds a new paragraph" "p" $'\nA brand new paragraph.' \
  'removed == [] and added in (["A brand new paragraph.", ""], ["", "A brand new paragraph."]) and N.count("A brand new paragraph.") == 1'
run_case "clicking in without typing never writes" "p" "" \
  'changed == [] and info.get("saveCount") == 0 and mtime_untouched'

echo
echo "$fails failed"
rm -rf "$WORK"
exit $(( fails > 0 ))
