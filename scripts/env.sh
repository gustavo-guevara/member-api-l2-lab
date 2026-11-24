# Environment for the member-api lab. Must be *sourced*:  source scripts/env.sh

# --- AWS Emulator (values from the official docs) ---
EMU_PORT="${EMU_PORT:-9297}"
EMU_DIR="$HOME/.aws/emulator/$EMU_PORT"
export AWS_ENDPOINT_URL="https://127.0.0.1:$EMU_PORT"
export AWS_SHARED_CREDENTIALS_FILE="$EMU_DIR/emulator_credentials"
export AWS_CONFIG_FILE="$EMU_DIR/config"
export AWS_CA_BUNDLE="$EMU_DIR/ca.pem"
export AWS_EC2_METADATA_DISABLED=true
export AWS_DISABLE_HOST_PREFIX_INJECTION=true
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

# --- Lab settings ---
export CONFIG_BUCKET=member-api-config
export LOGS_BUCKET=member-api-logs
export LOG_DIR=/var/log/member-api
export API_URL=http://127.0.0.1:8080

if [ -f "$AWS_CA_BUNDLE" ]; then
  echo "OK: S3 -> $AWS_ENDPOINT_URL | API -> $API_URL | DB -> 127.0.0.1:5432/memberdb"
else
  echo "WARNING: $AWS_CA_BUNDLE not found. Is aws-emulator running?"
fi
