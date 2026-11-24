#!/usr/bin/env bash
# Latency and errors per endpoint, from the API's access log.
#   bash scripts/latency.sh          last 1000 requests
#   bash scripts/latency.sh 200      last 200 requests
# Access log line: 2026-11-24 10:00:00 GET /claims?member_id=MBR-000001 200 12ms
LOG="${LOG_DIR:-/var/log/member-api}/access.log"
[ -s "$LOG" ] || { echo "no requests in $LOG yet"; exit 0; }

tail -n "${1:-1000}" "$LOG" | awk '{
    split($4, a, "?"); path = a[1]
    gsub(/MBR-[0-9]+/, "{id}", path)
    gsub(/\/[0-9]+\//, "/{id}/", path)
    ms = $6; sub("ms", "", ms)
    print $3 ":" path, ms, $5
  }' | sort -k1,1 -k2,2n | awk '
  function flush() {
    if (n == 0) return
    p50 = v[int(n * 0.50) > 0 ? int(n * 0.50) : 1]
    p95 = v[int(n * 0.95) > 0 ? int(n * 0.95) : 1]
    printf "%-34s %6d %8d %8d %8d %6d\n", ep, n, p50, p95, v[n], err
  }
  BEGIN { printf "%-34s %6s %8s %8s %8s %6s\n", "endpoint", "count", "p50_ms", "p95_ms", "max_ms", "5xx" }
  $1 != ep { flush(); ep = $1; n = 0; err = 0 }
  { v[++n] = $2; if ($3 >= 500) err++ }
  END { flush() }'
