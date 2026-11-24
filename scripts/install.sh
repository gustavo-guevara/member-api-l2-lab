#!/usr/bin/env bash
# One-time install: packages, the jar, and the systemd service.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="$(pwd)"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64) CLI_ARCH=x86_64 ;; arm64) CLI_ARCH=aarch64 ;; *) echo "Unsupported: $ARCH"; exit 1 ;; esac

echo "==> Packages: Java 21, Maven, PostgreSQL, curl, jq"
sudo apt-get update -qq
sudo apt-get install -y -qq openjdk-21-jdk-headless maven postgresql postgresql-client curl jq unzip >/dev/null

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if ! command -v aws-emulator >/dev/null; then
  echo "==> AWS Emulator"
  curl -fsSLo "$TMP/aws-emulator.deb" \
    "https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_${ARCH}.deb"
  sudo apt-get install -y "$TMP/aws-emulator.deb"
fi
if ! command -v aws >/dev/null; then
  echo "==> AWS CLI v2"
  curl -fsSLo "$TMP/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${CLI_ARCH}.zip"
  unzip -q "$TMP/awscliv2.zip" -d "$TMP" && sudo "$TMP/aws/install"
fi

echo "==> Building target/member-api.jar"
mvn -q -B clean package -DskipTests
ls -lh target/member-api.jar

echo "==> Installing systemd service member-api"
sed -e "s#__DIR__#$DIR#g" -e "s#__USER__#$(id -un)#g" systemd/member-api.service \
  | sudo tee /etc/systemd/system/member-api.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable member-api >/dev/null 2>&1

echo
echo "Done. Next: start aws-emulator in another terminal, then:"
echo "  source scripts/env.sh && bash scripts/setup.sh"
