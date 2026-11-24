#!/usr/bin/env bash
# INC-05: a user asks for a full-year claims report. The endpoint loads everything into memory.
cd "$(dirname "$0")/.."
FROM=$(date -d '365 days ago' +%F); TO=$(date +%F)
echo ">>> GET /reports/claims?from=$FROM&to=$TO"
curl -s -o /dev/null -m 120 -w "  -> HTTP %{http_code} after %{time_total}s\n" "$API_URL/reports/claims?from=$FROM&to=$TO" \
  || echo "  -> connection dropped (curl exit $?)"
sleep 8
echo ">>> Other users right after:"
curl -s -o /dev/null -m 10 -w "  -> /health HTTP %{http_code}\n" "$API_URL/health" || echo "  -> no answer"
echo
echo ">>> Ticket: 'Member API restarted by itself at $(date +%H:%M). Users saw errors for ~20 s.'"
echo ">>> Follow RUNBOOK.md INC-05."
