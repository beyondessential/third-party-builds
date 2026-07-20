#!/usr/bin/env bash
# Print candidate S3 object keys (stdin, one per line) that are NOT already
# recorded in the ingested-keys marker file ($1). A missing marker = first run
# / rebuild, so every candidate is treated as new.
set -euo pipefail
ingested=${1:?usage: select-new-debs.sh <ingested-keys-file> < candidates}
[ -f "$ingested" ] || ingested=/dev/null
grep -vxF -f "$ingested" || [ $? -eq 1 ]
