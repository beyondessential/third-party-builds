#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sel="$here/select-new-debs.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

printf '%s\n' a/1.deb b/2.deb > "$work/ingested"
out=$(printf '%s\n' a/1.deb b/2.deb c/3.deb | "$sel" "$work/ingested")
[ "$out" = "c/3.deb" ] || { echo "FAIL: expected c/3.deb, got: [$out]"; exit 1; }

out=$(printf '%s\n' a/1.deb | "$sel" "$work/does-not-exist")
[ "$out" = "a/1.deb" ] || { echo "FAIL: missing marker should yield all; got: [$out]"; exit 1; }

rc=0
out=$(printf '%s\n' a/1.deb b/2.deb | "$sel" "$work/ingested") || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: all-ingested should exit 0, got $rc"; exit 1; }
[ -z "$out" ] || { echo "FAIL: expected empty, got: [$out]"; exit 1; }

echo "ALL PASS"
