#!/usr/bin/env bash
# INC-04: someone enabled a debug trace "for 5 minutes" and forgot it. The log disk fills up.
cd "$(dirname "$0")/.."
head -c 200M /dev/zero > "$LOG_DIR/debug-trace.log" 2>/dev/null   # stops when the disk is full
bash scripts/load.sh 50 5 >/dev/null
sleep 1
echo ">>> df:"; df -h "$LOG_DIR"
echo ">>> /health:"; curl -s "$API_URL/health" | jq -c .
echo
echo ">>> Ticket: 'Monitoring: member-api DEGRADED, log volume at 100%.'"
echo ">>> Follow RUNBOOK.md INC-04."
