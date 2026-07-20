#!/usr/bin/env bash
# Normalise a .deb so it installs on old dpkg (Debian 11 / dpkg 1.20), which
# cannot read zstd-compressed members. Repacks to xz unless every control/data
# member is already xz or gzip (both readable by every relevant dpkg), in which
# case the input is copied through unchanged.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <in.deb> <out.deb>" >&2
  exit 2
fi
in=$1; out=$2

needs_repack=0
while IFS= read -r m; do
  case "$m" in
    control.tar.*|data.tar.*)
      case "$m" in
        *.tar.xz|*.tar.gz) ;;   # already old-dpkg-safe
        *) needs_repack=1 ;;    # zstd or anything else -> normalise
      esac
      ;;
  esac
done < <(ar t "$in")

if [ "$needs_repack" -eq 0 ]; then
  cp -- "$in" "$out"
  echo "passthrough: $in (already xz/gz)"
  exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dpkg-deb -R "$in" "$tmp/pkg"
dpkg-deb --root-owner-group -Z xz -b "$tmp/pkg" "$out" >/dev/null
echo "repacked: $in -> xz"
