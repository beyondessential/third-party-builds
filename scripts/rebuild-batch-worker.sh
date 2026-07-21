#!/usr/bin/env bash
# Runs INSIDE the rebuild container for ONE batch: download each source deb,
# repack it to xz, then deb-s3-upload the whole batch to the staging prefix.
# No credential logic here — it inherits fresh AWS creds from the environment
# (the host orchestrator exports them per batch, so they never expire mid-batch).
#
# Args: $1 = path to a file of source S3 keys (one per line)
# Env : BUCKET STAGING_PREFIX REGION ARCH GPG_KEY_ID
# Output: one "OK <key>" line per deb that was staged; exits non-zero if the
#         deb-s3 upload fails (so the orchestrator does not mark the batch done).
set -uo pipefail

batch=${1:?batch key-list file required}
: "${BUCKET:?}" "${STAGING_PREFIX:?}" "${REGION:?}" "${ARCH:?}" "${GPG_KEY_ID:?}"

# Stage inside the container's own filesystem (discarded on --rm) so nothing is
# written to a host mount as root.
staged=$(mktemp -d)
i=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  name=$(basename "$key")
  dl=0
  for attempt in 1 2 3 4; do
    if aws s3 cp "s3://$BUCKET/$key" /tmp/src.deb --only-show-errors; then dl=1; break; fi
    echo "  retry $attempt download: $key" >&2; sleep $((attempt * 3))
  done
  if [ "$dl" -ne 1 ]; then
    echo "SKIP download: $key" >&2; continue      # not marked done -> retried on next run
  fi
  if ! /repo/scripts/repack-to-xz.sh /tmp/src.deb "$staged/$(printf '%04d' "$i")-$name" >/dev/null; then
    echo "SKIP repack: $key" >&2; rm -f /tmp/src.deb; continue
  fi
  rm -f /tmp/src.deb
  i=$((i + 1))
  echo "OK $key"        # readable live progress AND the machine marker (grepped by the orchestrator)
done < "$batch"
echo "-- uploading $i staged packages via deb-s3 --"

[ "$i" -gt 0 ] || { echo "batch staged nothing" >&2; exit 0; }

deb-s3 upload \
  --bucket "$BUCKET" --prefix "$STAGING_PREFIX" \
  --s3-region "$REGION" \
  --codename stable --suite stable --component main --origin "BES Tools" \
  --arch "$ARCH" --preserve-versions --visibility nil \
  --sign="$GPG_KEY_ID" --gpg-options="--pinentry-mode loopback --batch --yes --no-tty" \
  "$staged/"*.deb
