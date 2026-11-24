-- L2 triage for member-api. Run all:  bash scripts/sql.sh -f sql/triage.sql
-- Most of these need superuser: scripts/sql.sh --admin -f sql/triage.sql

\echo '== Q1. Sessions doing something right now (oldest first)'
SELECT pid, application_name AS app, usename AS db_user, state,
       wait_event_type AS waiting_on,
       round(extract(epoch FROM now() - query_start)::numeric, 1) AS secs,
       left(regexp_replace(query, '\s+', ' ', 'g'), 70) AS query
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid() AND state <> 'idle'
ORDER BY query_start;

\echo '== Q2. Who is blocking whom (lock chains)'
SELECT blocked.pid                    AS blocked_pid,
       blocked.application_name       AS blocked_app,
       round(extract(epoch FROM now() - blocked.query_start)::numeric, 1) AS blocked_secs,
       blocker.pid                    AS blocker_pid,
       blocker.application_name       AS blocker_app,
       blocker.state                  AS blocker_state,
       round(extract(epoch FROM now() - blocker.xact_start)::numeric, 1)  AS blocker_xact_secs,
       left(regexp_replace(blocker.query, '\s+', ' ', 'g'), 60) AS blocker_last_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid) ON true
JOIN pg_stat_activity blocker ON blocker.pid = b.pid
ORDER BY blocked_secs DESC;

\echo '== Q3. Open transactions older than 30 s (the usual blockers)'
SELECT pid, application_name AS app, client_addr, state,
       round(extract(epoch FROM now() - xact_start)::numeric) AS xact_secs,
       left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS last_query
FROM pg_stat_activity
WHERE xact_start < now() - interval '30 seconds' AND pid <> pg_backend_pid()
ORDER BY xact_start;

\echo '== Q4. Connections by application and state (pool sizing)'
SELECT application_name AS app, state, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY 1, 2
ORDER BY 1, 2;

\echo '== Q5. Full table scans (a high seq_tup_read on a big table = missing index)'
SELECT relname AS table_name, seq_scan, seq_tup_read, idx_scan,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
ORDER BY seq_tup_read DESC;

\echo '== Q6. Indexes that exist and how often they are used'
SELECT relname AS table_name, indexrelname AS index_name, idx_scan
FROM pg_stat_user_indexes
ORDER BY relname, indexrelname;
