#!/usr/bin/env bash
# INC-01: a "cleanup" script dropped an index. Nothing errors, everything gets slow.
cd "$(dirname "$0")/.."
echo ">>> Baseline (healthy):"
bash scripts/load.sh 200 10
bash scripts/sql.sh -q -c "DROP INDEX IF EXISTS idx_claims_member_id; ANALYZE claims;"
echo
echo ">>> Same load after last night's DB maintenance:"
bash scripts/load.sh 200 10
echo
echo ">>> Ticket: 'Portal claim history is very slow since this morning. No errors.'"
echo ">>> Follow RUNBOOK.md INC-01."
