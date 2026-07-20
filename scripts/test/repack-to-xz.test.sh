#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repack="$here/repack-to-xz.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

pkg="$work/src"; mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/etc"
cat > "$pkg/DEBIAN/control" <<EOF
Package: fixture
Version: 1.0.0
Architecture: amd64
Maintainer: test <test@example.com>
Description: fixture package
EOF
printf '#!/bin/sh\necho hi\n' > "$pkg/usr/bin/fixture"; chmod 755 "$pkg/usr/bin/fixture"
# A maintainer script and a conffile, to prove the repack round-trip preserves them.
printf '#!/bin/sh\nexit 0\n' > "$pkg/DEBIAN/postinst"; chmod 755 "$pkg/DEBIAN/postinst"
printf 'setting=1\n' > "$pkg/etc/fixture.conf"
printf '/etc/fixture.conf\n' > "$pkg/DEBIAN/conffiles"

dpkg-deb --root-owner-group -Z zstd -b "$pkg" "$work/zstd.deb" >/dev/null
dpkg-deb --root-owner-group -Z xz   -b "$pkg" "$work/xz.deb"   >/dev/null
dpkg-deb --root-owner-group -Z gzip -b "$pkg" "$work/gz.deb"   >/dev/null

fail=0

# zstd -> repacked to xz
"$repack" "$work/zstd.deb" "$work/out-zstd.deb"
ar t "$work/out-zstd.deb" | grep -q '\.tar\.zst' && { echo "FAIL: zstd member remains"; fail=1; }
ar t "$work/out-zstd.deb" | grep -q 'control\.tar\.xz' || { echo "FAIL: control not xz"; fail=1; }
ar t "$work/out-zstd.deb" | grep -q 'data\.tar\.xz'    || { echo "FAIL: data not xz"; fail=1; }
dpkg-deb -I "$work/out-zstd.deb" >/dev/null || { echo "FAIL: output not a valid deb"; fail=1; }

# repack must preserve maintainer scripts + conffiles + payload
ctl="$work/ctl"; dpkg-deb -e "$work/out-zstd.deb" "$ctl"
[ -x "$ctl/postinst" ] || { echo "FAIL: postinst not preserved/executable"; fail=1; }
grep -qx '/etc/fixture.conf' "$ctl/conffiles" || { echo "FAIL: conffiles not preserved"; fail=1; }
root="$work/root"; dpkg-deb -x "$work/out-zstd.deb" "$root"
[ -f "$root/etc/fixture.conf" ] || { echo "FAIL: payload conffile not preserved"; fail=1; }

# xz -> passthrough (bytes unchanged)
"$repack" "$work/xz.deb" "$work/out-xz.deb"
cmp -s "$work/xz.deb" "$work/out-xz.deb" || { echo "FAIL: xz not passed through unchanged"; fail=1; }

# gz -> passthrough (bytes unchanged)
"$repack" "$work/gz.deb" "$work/out-gz.deb"
cmp -s "$work/gz.deb" "$work/out-gz.deb" || { echo "FAIL: gz not passed through unchanged"; fail=1; }

# usage error -> exit 2
rc=0; "$repack" only-one-arg >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: usage error exit not 2 (got $rc)"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || exit 1
