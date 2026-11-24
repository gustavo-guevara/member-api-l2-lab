#!/usr/bin/env bash
# Simulate users hitting the API and summarize what they experienced.
#   bash scripts/load.sh                    200 requests, 10 at a time, /claims
#   bash scripts/load.sh 500 20             500 requests, 20 at a time
#   bash scripts/load.sh 100 10 member      /members/{id} instead of /claims
set -uo pipefail
N="${1:-200}" C="${2:-10}" EP="${3:-claims}"
export URL="${API_URL:-http://127.0.0.1:8080}" EP

one() {
  local id path
  id=$(printf "MBR-%06d" $(( (RANDOM * 32768 + RANDOM) % 200000 + 1 )))
  case "$EP" in
    member) path="/members/$id" ;;
    search) path="/members?last_name=Lopez" ;;
    *)      path="/claims?member_id=$id" ;;
  esac
  curl -s -o /dev/null -m 60 -w "%{http_code} %{time_total}\n" "$URL$path"
}
export -f one

OUT="$(mktemp)"
START=$(date +%s.%N)
seq "$N" | xargs -P "$C" -I{} bash -c one > "$OUT"
END=$(date +%s.%N)

echo "load: $N requests, concurrency $C, endpoint $EP, $(awk -v a="$START" -v b="$END" 'BEGIN{printf "%.1f", b-a}') s"
echo -n "status codes: "
awk '{print $1}' "$OUT" | sort | uniq -c | awk '{printf "%s=%s  ", $2, $1}'; echo
awk '{print $2 * 1000}' "$OUT" | sort -n | awk '
  { v[NR] = $1 }
  END {
    if (NR == 0) { print "no responses"; exit }
    p50 = v[int(NR * 0.50) > 0 ? int(NR * 0.50) : 1]
    p95 = v[int(NR * 0.95) > 0 ? int(NR * 0.95) : 1]
    printf "latency ms: p50=%d  p95=%d  max=%d\n", p50, p95, v[NR]
  }'
rm -f "$OUT"
