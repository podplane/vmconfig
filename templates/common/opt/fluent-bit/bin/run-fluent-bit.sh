#!/usr/bin/env bash
set -e

log() { printf '[run-fluent-bit] %s\tts=%s\n' "$*" "$EPOCHREALTIME"; }

log "starting"
# shellcheck source=/dev/null
source /opt/env/fluent-bit.env
log "loaded /opt/env/fluent-bit.env"
args=(
)
export CLUSTER_ID
export INSTANCE_ID
export TELEMETRY_S3_BUCKET
export TELEMETRY_S3_ENDPOINT
export TELEMETRY_S3_REGION
export TELEMETRY_S3_ASSUME_ROLE
export TELEMETRY_OTLP_HOST
export TELEMETRY_OTLP_PORT
export TELEMETRY_OTLP_LOGS_URI
export TELEMETRY_OTLP_TLS
if [ "${TELEMETRY_S3_BUCKET:-}" != "" ] && [ "${TELEMETRY_S3_ASSUME_ROLE:-}" == "" ]; then
    export AWS_ACCESS_KEY_ID="${TELEMETRY_S3_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${TELEMETRY_S3_SECRET_ACCESS_KEY}"
fi
log "exec fluent-bit"
exec /opt/fluent-bit/bin/fluent-bit -c /opt/fluent-bit/etc/fluent-bit.yml "${args[@]}"
