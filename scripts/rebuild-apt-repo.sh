#!/usr/bin/env bash
# Rebuild the BES APT repo from source debs into a NON-LIVE staging prefix,
# verify it, then promote it over the live prefix. Runs on the HOST (where AWS
# SSO creds auto-refresh) and does the Debian-tooling work in short, batched
# rootful-podman containers built from scripts/rebuild.Containerfile.
#
# Why batched: fresh creds are exported per batch, so a batch always runs well
# inside the credential lifetime — a long rebuild cannot die from token expiry.
# Why resumable: every uploaded batch is recorded in a persistent marker; a
# rerun skips what is done and never clears the staging prefix. Pause / Ctrl-C /
# network drop -> just run `build` again and it continues.
#
# Prerequisites (host): aws CLI v2 with a working SSO profile, gpg with the repo
# signing key imported (build only), rootful podman (sudo).
#
# Usage:
#   GPG_KEY_ID=<id> AWS_PROFILE=<...:WriteAccess> scripts/rebuild-apt-repo.sh build
#                   AWS_PROFILE=<...:ReadAccess>  scripts/rebuild-apt-repo.sh verify
#                   AWS_PROFILE=<...:WriteAccess> scripts/rebuild-apt-repo.sh promote
#   FRESH=1 ... build     # discard prior staging + marker and start clean
set -uo pipefail

BUCKET=${BUCKET:-bes-ops-tools}
STAGING_PREFIX=${STAGING_PREFIX:-apt-next}
LIVE_PREFIX=${LIVE_PREFIX:-apt}
REGION=${REGION:-ap-southeast-2}
CF_DIST=${CF_DIST:-EDAG0UBS1MN74}
IMAGE=${IMAGE:-localhost/bes-apt-rebuild}
BATCH=${BATCH:-25}

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=${WORK:-$HOME/.cache/bes-apt-rebuild}
MARKER="$WORK/ingested.txt"           # source keys already uploaded to staging (persistent = resume)
AWS="aws --only-show-errors"
mkdir -p "$WORK"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# Same source-deb selection as the (incremental) CI job. Runs on the host.
list_candidates() { # $1 = target triple component (x86_64 | aarch64)
  local target=$1 dir
  for dir in aardvark-dns buildah crun krun libkrun libkrunfw netavark passt podman; do
    aws s3 ls "s3://$BUCKET/$dir/" --recursive | awk '{print $4}' \
      | grep -E "(^|/)$dir/.*-${target}-unknown-linux-gnu35-.*\.deb$" || true
  done
  for dir in caddy kopia bestool algae seedling; do
    aws s3 ls "s3://$BUCKET/$dir/" --recursive | awk '{print $4}' \
      | grep -E "(^|/)$dir/.*-${target}-.*\.deb$" || true
  done
  for dir in bestool-alertd bestool-psql; do
    aws s3 ls "s3://$BUCKET/$dir/" --recursive | awk '{print $4}' \
      | grep -E "(^|/)$dir/.*-${target}-.*\.deb$" | grep -v "/latest/" || true
  done
}

ensure_image() {
  if ! sudo -n podman image exists "$IMAGE" 2>/dev/null; then
    log "building container image $IMAGE (one-time)"
    sudo -n podman build -t "$IMAGE" -f "$HERE/rebuild.Containerfile" "$HERE" >&2 \
      || die "image build failed"
  fi
}

build() {
  : "${GPG_KEY_ID:?set GPG_KEY_ID to the signing key id}"
  command -v gpg >/dev/null || die "gpg not found on host"
  ensure_image

  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  local keyfile="$tmp/key.asc"
  gpg --export-secret-keys --armor "$GPG_KEY_ID" > "$keyfile" || die "could not export signing key"

  touch "$MARKER"
  if [ "${FRESH:-0}" = 1 ]; then
    log "FRESH: clearing staging s3://$BUCKET/$STAGING_PREFIX/ and marker"
    $AWS s3 rm "s3://$BUCKET/$STAGING_PREFIX/" --recursive || true
    : > "$MARKER"
  fi

  local pair arch target
  for pair in amd64:x86_64 arm64:aarch64; do
    arch=${pair%%:*}; target=${pair##*:}
    list_candidates "$target" > "$tmp/cand" || die "listing $arch candidates failed"
    grep -vxF -f "$MARKER" "$tmp/cand" > "$tmp/remaining" || true
    local total remaining have
    total=$(wc -l < "$tmp/cand"); remaining=$(wc -l < "$tmp/remaining"); have=$((total - remaining))
    log "=== $arch ($target): $total candidates, $have already done, $remaining to do ==="
    [ "$remaining" -eq 0 ] && { log "  $arch: nothing to do"; continue; }

    rm -f "$tmp"/batch-*
    split -l "$BATCH" -d "$tmp/remaining" "$tmp/batch-"
    local batches; batches=("$tmp"/batch-*)
    local bn=0 bf
    for bf in "${batches[@]}"; do
      bn=$((bn + 1))
      local n; n=$(wc -l < "$bf")
      log "  $arch batch $bn/${#batches[@]} ($n pkgs) — refreshing creds + running container"
      aws configure export-credentials --format env-no-export > "$tmp/creds.env" \
        || die "cred export failed (SSO session expired? run: aws-sso login -S BES)"
      echo "AWS_DEFAULT_REGION=$REGION" >> "$tmp/creds.env"

      # Mount the batch key-list read-only; the worker stages inside the
      # container (nothing root-owned is written to a host mount).
      if sudo -n podman run --rm \
           -v "$REPO:/repo:ro" -v "$bf:/batch.txt:ro" -v "$keyfile:/key.asc:ro" \
           --env-file "$tmp/creds.env" \
           -e BUCKET="$BUCKET" -e STAGING_PREFIX="$STAGING_PREFIX" -e REGION="$REGION" \
           -e ARCH="$arch" -e GPG_KEY_ID="$GPG_KEY_ID" \
           "$IMAGE" bash -euo pipefail -c \
             'gpg --batch --import /key.asc 2>/dev/null; exec /repo/scripts/rebuild-batch-worker.sh /batch.txt' \
           2>&1 | tee "$tmp/out"
      then
        grep '^OK ' "$tmp/out" | cut -d' ' -f2- >> "$MARKER"
        log "  $arch batch $bn done — marker now $(wc -l < "$MARKER") keys"
      else
        cat "$tmp/out" >&2
        die "$arch batch $bn failed. Progress saved ($(wc -l < "$MARKER") keys); rerun 'build' to resume."
      fi
    done
  done

  # Publish the public key alongside the repo (host has gpg + aws).
  gpg --export --armor "$GPG_KEY_ID" > "$tmp/bes-tools.gpg.key"
  $AWS s3 cp "$tmp/bes-tools.gpg.key" "s3://$BUCKET/$STAGING_PREFIX/bes-tools.gpg.key" || die "gpg key upload failed"

  log "=== BUILD COMPLETE -> s3://$BUCKET/$STAGING_PREFIX/ ($(wc -l < "$MARKER") packages) ==="
  log "next: '$0 verify' then '$0 promote'"
}

verify() {
  local rc=0 arch n manifest_total=0 tmp k
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  for arch in amd64 arm64; do
    if ! $AWS s3 cp "s3://$BUCKET/$STAGING_PREFIX/dists/stable/main/binary-$arch/Packages" "$tmp/pk-$arch" 2>/dev/null; then
      log "FAIL: no Packages for $arch"; rc=1; continue
    fi
    n=$(grep -c '^Package:' "$tmp/pk-$arch" || true); manifest_total=$((manifest_total + n))
    log "$arch: $n packages"
  done
  if $AWS s3 cp "s3://$BUCKET/$STAGING_PREFIX/dists/stable/InRelease" - 2>/dev/null | grep -q 'BEGIN PGP SIGNED MESSAGE'; then
    log "InRelease: signed OK"
  else
    log "FAIL: InRelease missing/unsigned"; rc=1
  fi
  if [ -f "$MARKER" ]; then
    log "manifest total=$manifest_total  marker keys=$(wc -l < "$MARKER" | tr -d ' ')"
  fi
  # xz spot-check: a few pool debs must be xz (no zstd survived repack).
  while read -r k; do
    [ -n "$k" ] || continue
    $AWS s3 cp "s3://$BUCKET/$k" "$tmp/s.deb" 2>/dev/null || continue
    ar t "$tmp/s.deb" 2>/dev/null | grep -q '\.tar\.zst' && { log "FAIL: zstd in $k"; rc=1; }
  done < <($AWS s3 ls "s3://$BUCKET/$STAGING_PREFIX/pool/" --recursive 2>/dev/null | awk '{print $4}' | grep '\.deb$' | head -6)
  [ "$rc" -eq 0 ] && log "=== VERIFY OK ===" || log "=== VERIFY FAILED ==="
  return $rc
}

promote() {
  [ -f "$MARKER" ] || die "no marker ($MARKER) — run 'build' first"
  log "promoting s3://$BUCKET/$STAGING_PREFIX/ -> s3://$BUCKET/$LIVE_PREFIX/ (--delete)"
  $AWS s3 sync "s3://$BUCKET/$STAGING_PREFIX/" "s3://$BUCKET/$LIVE_PREFIX/" --delete --copy-props none || die "promote sync failed"
  log "updating incremental marker s3://$BUCKET/apt-state/ingested-keys.txt"
  $AWS s3 cp "$MARKER" "s3://$BUCKET/apt-state/ingested-keys.txt" || die "marker upload failed"
  log "invalidating CloudFront /$LIVE_PREFIX/*"
  aws cloudfront create-invalidation --distribution-id "$CF_DIST" --paths "/$LIVE_PREFIX/*" >/dev/null || die "cloudfront invalidation failed"
  log "=== PROMOTED ==="
}

case "${1:-}" in
  build)   build ;;
  verify)  verify ;;
  promote) promote ;;
  *) echo "usage: $0 build|verify|promote"; exit 2 ;;
esac
