#!/usr/bin/env bash
# deb-s3 cannot set the Release Label/Description (only origin/suite/codename).
# apt refuses to update a repo whose Label *changes* ("changed its 'Label' value
# ... must be accepted explicitly"), so after any deb-s3 publish we must restore:
#   Label: BES Tools
#   Description: Tools and runtimes for BES deployments
# This downloads the Release for a prefix, ensures those fields (idempotent),
# re-signs InRelease + Release.gpg, and re-uploads. Editing the Release header
# does not affect the Packages hashes it lists, so the signature stays valid.
#
# Needs: aws creds + the signing key in the local gpg keyring (GPG_KEY_ID).
# Usage: GPG_KEY_ID=<id> [BUCKET=..] scripts/ensure-release-label.sh [prefix]   # prefix default: apt
set -euo pipefail

BUCKET=${BUCKET:-bes-ops-tools}
PREFIX=${1:-apt}
LABEL=${LABEL:-BES Tools}
DESCRIPTION=${DESCRIPTION:-Tools and runtimes for BES deployments}
: "${GPG_KEY_ID:?set GPG_KEY_ID to the signing key id}"

base="s3://$BUCKET/$PREFIX/dists/stable"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

aws s3 cp "$base/Release" "$tmp/Release" --only-show-errors

changed=0
if ! grep -q '^Label:' "$tmp/Release"; then
  sed -i "/^Origin:/a Label: $LABEL" "$tmp/Release"; changed=1
fi
if ! grep -q '^Description:' "$tmp/Release"; then
  sed -i "/^Label:/a Description: $DESCRIPTION" "$tmp/Release"; changed=1
fi

if [ "$changed" -eq 0 ]; then
  echo "Release already has Label + Description; nothing to do"
  exit 0
fi

gpg --batch --yes --pinentry-mode loopback --default-key "$GPG_KEY_ID" --clearsign -o "$tmp/InRelease" "$tmp/Release"
gpg --batch --yes --pinentry-mode loopback --default-key "$GPG_KEY_ID" -abs -o "$tmp/Release.gpg" "$tmp/Release"

aws s3 cp "$tmp/Release"    "$base/Release"    --only-show-errors
aws s3 cp "$tmp/InRelease"  "$base/InRelease"  --only-show-errors
aws s3 cp "$tmp/Release.gpg" "$base/Release.gpg" --only-show-errors
echo "restored Label='$LABEL' + Description on $base and re-signed"
