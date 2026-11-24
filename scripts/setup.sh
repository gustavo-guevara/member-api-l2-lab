#!/usr/bin/env bash
# Database, data, log disk, S3 buckets and config, then start the service.
# Safe to run more than once. Re-run after every emulator restart (S3 lives in memory).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${AWS_ENDPOINT_URL:?run: source scripts/env.sh}"

echo "==> PostgreSQL: role api, database memberdb"
pgadmin() { (cd /tmp && sudo -u postgres psql "$@"); }   # cd: postgres cannot read your folder
sudo systemctl start postgresql
pgadmin -q -tc "SELECT 1 FROM pg_roles WHERE rolname='api'" | grep -q 1 \
  || pgadmin -q -c "CREATE ROLE api LOGIN PASSWORD 'api';"
pgadmin -q -tc "SELECT 1 FROM pg_database WHERE datname='memberdb'" | grep -q 1 \
  || pgadmin -q -c "CREATE DATABASE memberdb OWNER api;"
# Lab only: a password for the admin role so triage can run as your own Linux user
pgadmin -q -c "ALTER ROLE postgres PASSWORD 'postgres';"
PGPASSWORD=api psql -q -h 127.0.0.1 -U api -d memberdb -v ON_ERROR_STOP=1 \
  -c "SET client_min_messages=warning;" -f sql/schema.sql

if [ "$(PGPASSWORD=api psql -h 127.0.0.1 -U api -d memberdb -tAc 'SELECT count(*) FROM members')" = "0" ]; then
  echo "==> Loading synthetic data (200k members, 1.5M claims, about a minute)"
  PGPASSWORD=api psql -q -h 127.0.0.1 -U api -d memberdb -v ON_ERROR_STOP=1 -f sql/seed.sql
else
  echo "==> Data already loaded"
fi

echo "==> Log disk: 64 MB at $LOG_DIR (small on purpose, see INC-04)"
sudo mkdir -p "$LOG_DIR"
if ! mountpoint -q "$LOG_DIR"; then
  sudo mount -t tmpfs -o "size=64m,mode=0755,uid=$(id -u),gid=$(id -g)" tmpfs "$LOG_DIR"
fi

echo "==> S3: buckets and config"
for b in "$CONFIG_BUCKET" "$LOGS_BUCKET"; do
  aws s3api head-bucket --bucket "$b" 2>/dev/null || aws s3api create-bucket --bucket "$b" >/dev/null
done
aws s3 cp config/application.properties "s3://$CONFIG_BUCKET/application.properties" >/dev/null
aws s3 cp config/application.properties "s3://$CONFIG_BUCKET/application.properties.last-known-good" >/dev/null

echo "==> Starting member-api"
sudo systemctl reset-failed member-api 2>/dev/null || true
sudo systemctl restart member-api
for i in $(seq 1 30); do
  if curl -sf "$API_URL/health" >/dev/null; then break; fi
  sleep 1
done
curl -s "$API_URL/health" | jq . || { echo "API did not come up: sudo journalctl -u member-api -n 30"; exit 1; }
echo "Setup complete."
