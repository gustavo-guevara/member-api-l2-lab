#!/usr/bin/env bash
# psql on memberdb.
#   bash scripts/sql.sh                     as the app user (api)
#   bash scripts/sql.sh --admin             as postgres (sees every session, can terminate them)
#   bash scripts/sql.sh --admin -f sql/triage.sql
if [ "${1:-}" = "--admin" ]; then
  shift
  PGPASSWORD=postgres exec psql -h 127.0.0.1 -U postgres -d memberdb -P pager=off "$@"
fi
PGPASSWORD=api exec psql -h 127.0.0.1 -U api -d memberdb -P pager=off "$@"
