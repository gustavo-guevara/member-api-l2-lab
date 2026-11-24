#!/usr/bin/env bash
# INC-03: a password rotation was pushed to the config in S3, but the DB was never changed.
# Nothing breaks until the next restart (a deploy, a reboot, an OOM)...
cd "$(dirname "$0")/.."
sed 's/^db.password=.*/db.password=Winter2026!/' config/application.properties > /tmp/application.properties
aws s3 cp /tmp/application.properties "s3://$CONFIG_BUCKET/application.properties" >/dev/null
echo ">>> Config updated in S3 at $(date +%T). API still fine: $(curl -s "$API_URL/health" | jq -r .status)"
echo ">>> Routine restart during the change window..."
sudo systemctl restart member-api
sleep 25
systemctl status member-api --no-pager | head -6
echo
echo ">>> Ticket: 'Member API down after the change window. Health check returns nothing.'"
echo ">>> Follow RUNBOOK.md INC-03."
