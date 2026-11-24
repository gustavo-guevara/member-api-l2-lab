# Member API L2 Support Lab

A **Java** API running 24/7 the way production support sees it: a **systemd** service on
**Linux**, a **PostgreSQL** database behind a connection pool, configuration and log archives
in **S3**. Then five realistic incidents to diagnose with logs, `systemctl`, `journalctl` and **SQL**.

Runs on your machine: **AWS Emulator** (AWS's official local emulator) inside a **Multipass**
Ubuntu VM. No AWS account, no cloud bill.

> All data is synthetic: 200,000 invented members and 1.5 million claims.

## How it works

```
                       s3://member-api-config/application.properties
                                     │ read at startup
 users ──HTTP──► member-api (Java, systemd, port 8080)
                    │  HikariCP pool (5 connections, 3 s wait, 30 s statement timeout)
                    ▼
               PostgreSQL memberdb: members (200k), claims (1.5M)

 /var/log/member-api/access.log (64 MB disk) ──archive_logs.sh──► s3://member-api-logs/
```

| Endpoint | What it does |
|---|---|
| `GET /health` | Status, DB check, pool usage, log disk space |
| `GET /members/{id}` | One member |
| `GET /claims?member_id=` | A member's last 100 claims |
| `POST /claims/{id}/status?value=` | Approve, deny, pay a claim |
| `GET /reports/claims?from=&to=` | Claims in a date range |

## Setup

Uses the same Multipass VM as the other labs. Put this folder **outside iCloud**
(for example `~/dev`), then on your Mac:

```bash
multipass mount ~/dev/member-api-l2-lab aws-lab:/home/ubuntu/api
```

Inside the VM (`multipass shell aws-lab`):

```bash
cd ~/api
bash scripts/install.sh            # packages, jar, systemd service

# Terminal 1
aws-emulator

# Terminal 2
cd ~/api
source scripts/env.sh
bash scripts/setup.sh              # DB + data, log disk, S3 config, starts the service
bash scripts/healthcheck.sh        # should end in HEALTHY
```

## Try it

```bash
curl -s localhost:8080/health | jq .
curl -s localhost:8080/members/MBR-000123 | jq .
curl -s "localhost:8080/claims?member_id=MBR-000123" | jq '.[0:3]'
bash scripts/load.sh 200 10        # what users experience: status codes, p50/p95
bash scripts/latency.sh            # per endpoint, from the access log
```

## Incidents

| ID | Inject | Ticket says |
|---|---|---|
| INC-01 | `bash incidents/01_slow_claims.sh` | "Claim history very slow since this morning, no errors" |
| INC-02 | `bash incidents/02_blocked_updates.sh` | "API timing out for everyone, approvals stuck" |
| INC-03 | `bash incidents/03_bad_config.sh` | "API down after the change window" |
| INC-04 | `bash incidents/04_disk_full.sh` | "Monitoring: DEGRADED, log volume at 100%" |
| INC-05 | `bash incidents/05_report_oom.sh` | "API restarted by itself, users saw errors" |

Diagnose with the tools in [RUNBOOK.md](RUNBOOK.md) before reading its fix.

## What this demonstrates

- Running and troubleshooting a **systemd** service: restart policies, start limits, `journalctl`
- **Connection pool** behaviour: why one blocked query can take down every endpoint
- **PostgreSQL triage**: `pg_stat_activity`, lock chains with `pg_blocking_pids`, `EXPLAIN ANALYZE`,
  table scan statistics, `CREATE INDEX CONCURRENTLY`, `pg_terminate_backend`
- **Config as a dependency**: a bad value in S3 breaks the next restart, and how to roll back
- **Log management**: disk exhaustion, archiving to S3 before deleting
- **JVM failure modes**: `OutOfMemoryError`, exit codes, auto-restart, when to escalate to development
- Latency as a symptom: p50/p95 from the access log, not only error counts

## Notes

- S3 lives in the emulator's memory: after restarting `aws-emulator`, run `source scripts/env.sh`
  and `bash scripts/setup.sh` again. The service will fail to start until the config exists again
  (which is itself a good exercise).
- The log disk is a 64 MB in-memory volume (`tmpfs`) so INC-04 never fills the real disk.
  It is recreated by `setup.sh` after a VM reboot.
- AWS Emulator docs: https://docs.aws.amazon.com/emulator/
