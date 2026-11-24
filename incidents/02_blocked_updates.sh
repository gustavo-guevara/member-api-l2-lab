#!/usr/bin/env bash
# INC-02: someone ran a manual fix in a SQL tool and never committed.
# Their open transaction holds a row lock; API updates queue behind it,
# they hold pool connections while they wait, and the whole API starves.
cd "$(dirname "$0")/.."
( echo "BEGIN;"
  echo "UPDATE claims SET status = 'IN_REVIEW' WHERE claim_id = 42;"
  sleep 900                     # the person went to lunch; transaction stays open
  echo "ROLLBACK;"
) | PGAPPNAME="toad-CHG1042-jperez" PGPASSWORD=api psql -q -h 127.0.0.1 -U api -d memberdb >/dev/null 2>&1 &
sleep 2
echo ">>> The portal keeps retrying the approval of claim 42 (6 at a time, until one succeeds)..."
( end=$((SECONDS + 900))
  while [ $SECONDS -lt $end ]; do
    codes=$(for i in 1 2 3 4 5 6; do
              curl -s -o /dev/null -m 45 -w '%{http_code}\n' -X POST "$API_URL/claims/42/status?value=APPROVED" &
            done; wait)
    echo "$codes" | grep -q '^200$' && break
  done ) >/dev/null 2>&1 &
sleep 6
echo ">>> Meanwhile, a normal read from another user:"
curl -s -m 10 -w "  -> HTTP %{http_code} in %{time_total}s\n" "$API_URL/claims?member_id=MBR-000123" | tail -c 120; echo
echo ">>> /health:"
curl -s -m 10 "$API_URL/health" | jq -c .
echo
echo ">>> Ticket: 'Member API timing out for everyone. Claim approvals stuck.'"
echo ">>> Follow RUNBOOK.md INC-02. (The blocking session stays open 15 minutes unless you act.)"
