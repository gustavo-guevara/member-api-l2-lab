#!/usr/bin/env bash
# What systemd runs (ExecStart). Not meant to be run by hand: use
#   sudo systemctl start|stop|restart member-api
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

# Java must trust the emulator's certificate. The emulator makes a new one on
# every start, so rebuild the truststore whenever ca.pem changes.
TS="$HOME/.cache/member-api/emulator-truststore.p12"
if [ -f "$AWS_CA_BUNDLE" ] && { [ ! -f "$TS" ] || [ "$AWS_CA_BUNDLE" -nt "$TS" ]; }; then
  mkdir -p "$(dirname "$TS")" && rm -f "$TS"
  keytool -importcert -noprompt -alias aws-emulator -file "$AWS_CA_BUNDLE" \
    -keystore "$TS" -storetype PKCS12 -storepass changeit >/dev/null 2>&1
fi

# Small heap on purpose (INC-05). ExitOnOutOfMemoryError: die fast and let systemd restart,
# instead of limping along half-broken.
exec java -Xms64m -Xmx160m -XX:+ExitOnOutOfMemoryError \
  -Djavax.net.ssl.trustStore="$TS" -Djavax.net.ssl.trustStorePassword=changeit \
  -Djavax.net.ssl.trustStoreType=PKCS12 \
  -jar target/member-api.jar
