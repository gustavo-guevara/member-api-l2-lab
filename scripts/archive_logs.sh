#!/usr/bin/env bash
# Ship logs to S3 and free the local disk.
#   bash scripts/archive_logs.sh --dry-run    show what would move
#   bash scripts/archive_logs.sh              compress, upload, then delete / truncate
# Every file except access.log is uploaded and deleted.
# access.log is uploaded and then truncated in place: the API keeps writing to it.
set -uo pipefail
: "${AWS_ENDPOINT_URL:?run: source scripts/env.sh}"
DIR="${LOG_DIR:-/var/log/member-api}"
DRY="${1:-}"
PREFIX="s3://$LOGS_BUCKET/$(hostname)/$(date +%F)"
STAMP="$(date +%H%M%S)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # /tmp is on the VM disk, not the full log disk

echo "before: $(df -h --output=used,size,pcent "$DIR" | tail -1)"
for f in "$DIR"/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  size="$(du -h "$f" | cut -f1)"
  if [ "$DRY" = "--dry-run" ]; then
    echo "would archive $name ($size) -> $PREFIX/${name}.${STAMP}.gz"
    continue
  fi
  gzip -c "$f" > "$TMP/$name.gz" || { echo "FAIL gzip $name"; continue; }
  if aws s3 cp "$TMP/$name.gz" "$PREFIX/${name}.${STAMP}.gz" >/dev/null; then
    if [ "$name" = "access.log" ]; then : > "$f"; else rm -f "$f"; fi
    echo "archived $name ($size) -> $PREFIX/${name}.${STAMP}.gz"
  else
    echo "FAIL upload $name: left in place"
  fi
done
echo "after:  $(df -h --output=used,size,pcent "$DIR" | tail -1)"
