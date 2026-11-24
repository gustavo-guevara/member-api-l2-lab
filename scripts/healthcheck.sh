#!/usr/bin/env bash
# Every dependency of member-api, from the outside in. Exit 0 = healthy.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
ok()   { printf "  [ OK ] %s\n" "$1"; }
bad()  { printf "  [FAIL] %s\n" "$1"; FAIL=1; }
warn() { printf "  [WARN] %s\n" "$1"; }
[ -n "${AWS_ENDPOINT_URL:-}" ] || { echo "AWS_ENDPOINT_URL not set (source scripts/env.sh)"; exit 1; }

echo "1) AWS Emulator / S3"
if aws sts get-caller-identity >/dev/null 2>&1; then
  ok "emulator reachable"
  aws s3api head-object --bucket "$CONFIG_BUCKET" --key application.properties >/dev/null 2>&1 \
    && ok "config s3://$CONFIG_BUCKET/application.properties" || bad "config missing (bash scripts/setup.sh)"
  aws s3api head-bucket --bucket "$LOGS_BUCKET" >/dev/null 2>&1 && ok "bucket $LOGS_BUCKET" || bad "bucket $LOGS_BUCKET missing"
else
  bad "emulator not responding (is aws-emulator running?)"
fi

echo "2) PostgreSQL"
pg_isready -h 127.0.0.1 -p 5432 -q && ok "accepting connections" || bad "down (sudo systemctl start postgresql)"

echo "3) Log disk $LOG_DIR"
if mountpoint -q "$LOG_DIR"; then
  pct=$(df --output=pcent "$LOG_DIR" | tail -1 | tr -dc 0-9)
  if [ "$pct" -ge 90 ]; then bad "${pct}% used (RUNBOOK INC-04)"; else ok "${pct}% used"; fi
else
  bad "not mounted (bash scripts/setup.sh)"
fi

echo "4) Service member-api (systemd)"
state=$(systemctl is-active member-api 2>/dev/null)
restarts=$(systemctl show -p NRestarts --value member-api 2>/dev/null)
since=$(systemctl show -p ActiveEnterTimestamp --value member-api 2>/dev/null)
if [ "$state" = "active" ]; then ok "active since $since"; else bad "state=$state (sudo journalctl -u member-api -n 30)"; fi
[ "${restarts:-0}" -gt 0 ] && warn "systemd restarted it automatically $restarts time(s) (crash or OOM: check the journal)"

echo "5) HTTP /health"
body=$(curl -s -m 10 -w "\n%{http_code}" "$API_URL/health")
code=$(echo "$body" | tail -1)
json=$(echo "$body" | sed '$d')
if [ "$code" = "200" ]; then
  st=$(echo "$json" | jq -r .status)
  [ "$st" = "UP" ] && ok "UP" || warn "$st"
  echo "$json" | jq -c '{db, pool, log_disk_free_pct, uptime_s}' | sed 's/^/         /'
else
  bad "HTTP ${code:-no answer}"
  [ -n "$json" ] && echo "$json" | jq -c . 2>/dev/null | sed 's/^/         /'
fi

echo
[ $FAIL -eq 0 ] && echo "HEALTHY" || echo "UNHEALTHY"
exit $FAIL
