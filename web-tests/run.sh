#!/usr/bin/env bash
# Run every web-side test (each *-test.sh renders through the real WKWebView headlessly).
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in ./*-test.sh; do
  echo "== $t"; bash "$t" || rc=1
done
exit $rc
