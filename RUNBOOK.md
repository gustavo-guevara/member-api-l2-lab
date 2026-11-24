# Runbook: member-api

Java HTTP API (port 8080) run by systemd as `member-api`. Reads its config from
`s3://member-api-config/application.properties` at startup, uses PostgreSQL `memberdb`
through a HikariCP pool of 5 connections, writes `access.log` to `/var/log/member-api`.

## Where to look

| Question | Command |
|---|---|
| Is everything up? | `bash scripts/healthcheck.sh` |
| Is the process running, how often did it restart? | `systemctl status member-api --no-pager` |
| What did the app say? | `sudo journalctl -u member-api -n 50 --no-pager` |
| Which endpoint is slow or failing? | `bash scripts/latency.sh` |
| What is the database doing? | `bash scripts/sql.sh --admin -f sql/triage.sql` |
| How does it feel to users? | `bash scripts/load.sh 100 10` |

## Exit codes and HTTP codes

| Code | Where | Meaning |
|---|---|---|
| exit 2 | journal | Config could not be loaded from S3, or a key is missing/invalid |
| exit 4 | journal | Database rejected the connection at startup (down, wrong password) |
| exit 3 | journal | `Terminating due to java.lang.OutOfMemoryError` — the JVM killed itself |
| HTTP 503 `pool exhausted` | access log / client | No free DB connection within 3 s |
| HTTP 504 `query timed out` | access log / client | A query ran past the 30 s statement timeout |
| `/health` DEGRADED | health | Log disk < 10% free, or requests waiting for a connection |
| `/health` 503 DOWN | health | The API cannot get a DB connection at all |

---

## INC-01: everything is slow, no errors

**Check:**

```bash
bash scripts/latency.sh                  # which endpoint? GET:/claims p95 in seconds
bash scripts/sql.sh --admin -f sql/triage.sql   # Q5: claims seq_tup_read in the millions
bash scripts/sql.sh -c "EXPLAIN ANALYZE SELECT * FROM claims WHERE member_id = 'MBR-000123';"
```

`Seq Scan on claims` + "Rows Removed by Filter: ~1,500,000" = reading the whole table for
every request. Q6 shows `idx_claims_member_id` is gone.

**Root cause:** the index on `claims(member_id)` was dropped (maintenance script, bad migration).
**Fix:** recreate it without locking the table, then confirm the plan and the latency:

```bash
bash scripts/sql.sh -c "CREATE INDEX CONCURRENTLY idx_claims_member_id ON claims (member_id);"
bash scripts/sql.sh -c "EXPLAIN SELECT * FROM claims WHERE member_id = 'MBR-000123';"   # Index Scan
bash scripts/load.sh 200 10
```

**Why CONCURRENTLY:** a plain `CREATE INDEX` blocks writes to the table while it builds.
**Prevent:** schema changes go through review; alert on p95 latency, not only on errors.

## INC-02: API timing out for everyone, approvals stuck

**Check:**

```bash
curl -s localhost:8080/health | jq .pool      # active = max, waiting > 0
sudo journalctl -u member-api -n 20 --no-pager | grep -E "pool exhausted|timeout"
bash scripts/sql.sh --admin -f sql/triage.sql # Q1 waiting_on=Lock, Q2/Q3 show the blocker
```

Q3 shows a session from `toad-CHG1042-jperez`, state `idle in transaction`, open for minutes.
Q2 shows every `member-api` update waiting on that PID.

**Root cause:** someone ran an `UPDATE` by hand for change CHG1042 and never committed.
Their row lock blocks the API's updates of claim 42; each blocked request holds one of the
5 pool connections for up to 30 s, so reads for *other* members also fail with 503.
One forgotten transaction takes down the whole API.

**Fix:**
1. Contact the session owner (application name and change number tell you who). Ask them to commit or roll back.
2. If they can't be reached and the business impact justifies it, get approval and terminate it.
   Their uncommitted change is rolled back:

```bash
bash scripts/sql.sh --admin -c "SELECT pg_terminate_backend(<blocker_pid>);"
curl -s localhost:8080/health | jq .pool      # waiting back to 0
```

**Never** terminate `member-api` sessions: they are the victims, not the cause.
**Prevent:** `idle_in_transaction_session_timeout` on the database; manual changes with autocommit
or a peer; alert on transactions open longer than a few minutes.

## INC-03: service down after a restart, keeps restarting

**Check:**

```bash
systemctl status member-api --no-pager        # "activating (auto-restart)" or "failed ... start-limit-hit"
sudo journalctl -u member-api -n 30 --no-pager
```

The journal repeats `FATAL database init failed: PSQLException: FATAL: password authentication failed for user "api"`
and `Main process exited, code=exited, status=4`. systemd retried 5 times in 60 s and gave up.

```bash
aws s3 cp s3://member-api-config/application.properties - > /tmp/now.properties
aws s3 cp s3://member-api-config/application.properties.last-known-good - > /tmp/lkg.properties
diff /tmp/lkg.properties /tmp/now.properties
```

**Root cause:** the password in the S3 config was changed, the database password was not.
The bad config sat unnoticed until the restart.
**Fix:** restore the last known good config, clear systemd's failure counter, start:

```bash
aws s3 cp s3://member-api-config/application.properties.last-known-good s3://member-api-config/application.properties
sudo systemctl reset-failed member-api
sudo systemctl start member-api
bash scripts/healthcheck.sh
```

**Prevent:** validate config before publishing it; rotate DB and config passwords in the same change;
restart one instance first (canary) after any config change.

## INC-04: log disk full

**Check:**

```bash
df -h /var/log/member-api                     # 100%
du -sh /var/log/member-api/*                  # debug-trace.log is the culprit
sudo journalctl -u member-api -n 20 --no-pager | grep "access log write failed"
```

The API keeps serving (by design), but `/health` is DEGRADED and requests are no longer logged:
you are blind for any other incident.

**Root cause:** a debug trace was left on and filled the 64 MB log volume.
**Fix:** archive to S3 before deleting, so nothing is lost for audits:

```bash
bash scripts/archive_logs.sh --dry-run
bash scripts/archive_logs.sh
aws s3 ls s3://member-api-logs/ --recursive | tail -5
```

**Prevent:** scheduled log archiving (cron), size limits on debug output, alert at 80% disk.

## INC-05: the API restarted by itself

**Check:**

```bash
systemctl status member-api --no-pager        # recent start time
systemctl show -p NRestarts member-api
sudo journalctl -u member-api --since "15 min ago" --no-pager | grep -B2 -A3 -i "outofmemory\|exited"
grep reports /var/log/member-api/access.log | tail -3
```

`Terminating due to java.lang.OutOfMemoryError: Java heap space`, then
`Main process exited, code=exited, status=3`, then a new start. The access log has no line for the
report request: the process died before answering.

**Root cause:** `/reports/claims` loads the whole date range into memory. One year = 1.5M rows, far
beyond the 160 MB heap.
**Fix now:** systemd already restarted the service. Ask the user to request shorter ranges (a week or a month).
**Fix for real:** escalate to development with the evidence (endpoint, parameters, journal lines):
the endpoint must stream or paginate. Raising `-Xmx` only moves the limit.
**Prevent:** limit the allowed date range in the API; alert on any automatic restart.
