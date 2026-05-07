#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Load helpers
SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../helpers.sh"

# Load env files
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/detected.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/mutable.env"

# Set vars
default_s3_endpoint=""
telemetry_s3_assume_role="${TELEMETRY_S3_ASSUME_ROLE:-}"
if [ "${PROVIDER_KIND:-}" = "aws" ] && [ -n "${TELEMETRY_S3_BUCKET:-}" ]; then
  require_nonempty AWS_ACCOUNT_ID
  require_nonempty CLUSTER_ID
  default_s3_endpoint="s3.${PROVIDER_REGION:-}.amazonaws.com"
  telemetry_s3_assume_role="arn:aws:iam::${AWS_ACCOUNT_ID}:role/podplane-${CLUSTER_ID}-telemetry-upload"
fi

case "${TELEMETRY_ENABLED:-false}" in
  true|false) ;;
  *) fatal "TELEMETRY_ENABLED must be true or false" ;;
esac
case "${TELEMETRY_LOG_CLOUDINIT:-true}" in
  true|false) include_cloudinit="${TELEMETRY_LOG_CLOUDINIT:-true}" ;;
  *) fatal "TELEMETRY_LOG_CLOUDINIT must be true or false" ;;
esac
allowed_units="|"
IFS=',' read -ra services <<< "${TELEMETRY_LOG_SERVICES:-}"
for service in "${services[@]}"; do
  service="${service//[[:space:]]/}"
  [ -n "$service" ] || continue
  unit="${service}.service"
  allowed_units="${allowed_units}${unit}|"
done
include_s3=false
include_otlp=false
telemetry_otlp_host=""
telemetry_otlp_port=""
telemetry_otlp_logs_uri="/v1/logs"
telemetry_otlp_tls="false"
if [ "${TELEMETRY_ENABLED:-false}" = true ]; then
  [ -n "${TELEMETRY_S3_BUCKET:-}" ] && include_s3=true
  if [ -n "${TELEMETRY_OTLP_ENDPOINT:-}" ]; then
    include_otlp=true
    case "$TELEMETRY_OTLP_ENDPOINT" in
      http://*) telemetry_otlp_tls=false; otlp_endpoint="${TELEMETRY_OTLP_ENDPOINT#http://}" ;;
      https://*) telemetry_otlp_tls=true; otlp_endpoint="${TELEMETRY_OTLP_ENDPOINT#https://}" ;;
      *) fatal "TELEMETRY_OTLP_ENDPOINT must start with http:// or https://" ;;
    esac
    telemetry_otlp_host_port="${otlp_endpoint%%/*}"
    telemetry_otlp_path="${otlp_endpoint#*/}"
    if [ "$telemetry_otlp_path" != "$otlp_endpoint" ] && [ -n "$telemetry_otlp_path" ]; then
      telemetry_otlp_logs_uri="/${telemetry_otlp_path}"
    fi
    telemetry_otlp_host="${telemetry_otlp_host_port%%:*}"
    telemetry_otlp_port="${telemetry_otlp_host_port#*:}"
    if [ "$telemetry_otlp_port" = "$telemetry_otlp_host_port" ]; then
      if [ "$telemetry_otlp_tls" = true ]; then
        telemetry_otlp_port="443"
      else
        telemetry_otlp_port="80"
      fi
    fi
    [ -n "$telemetry_otlp_host" ] || fatal "TELEMETRY_OTLP_ENDPOINT must include a host"
  fi
  if [ "$include_s3" != true ] && [ "$include_otlp" != true ]; then
    fatal "TELEMETRY_ENABLED=true requires TELEMETRY_S3_BUCKET or TELEMETRY_OTLP_ENDPOINT"
  fi
  if [ "$allowed_units" = "|" ] && [ "$include_cloudinit" != true ]; then
    fatal "TELEMETRY_ENABLED=true requires TELEMETRY_LOG_SERVICES or TELEMETRY_LOG_CLOUDINIT=true"
  fi
fi

# Create fluent-bit env file
mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/fluent-bit.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
CLUSTER_ID=$(quote_env_value "${CLUSTER_ID:-}")
INSTANCE_ID=$(quote_env_value "${INSTANCE_ID:-}")
TELEMETRY_ENABLED=$(quote_env_value "${TELEMETRY_ENABLED:-false}")
TELEMETRY_LOG_SERVICES=$(quote_env_value "${TELEMETRY_LOG_SERVICES:-}")
TELEMETRY_LOG_CLOUDINIT=$include_cloudinit
TELEMETRY_S3_BUCKET=$(quote_env_value "${TELEMETRY_S3_BUCKET:-}")
TELEMETRY_S3_ENDPOINT=$(quote_env_value "${TELEMETRY_S3_ENDPOINT:-$default_s3_endpoint}")
TELEMETRY_S3_REGION=$(quote_env_value "${TELEMETRY_S3_REGION:-${PROVIDER_REGION:-}}")
TELEMETRY_S3_ASSUME_ROLE=$(quote_env_value "$telemetry_s3_assume_role")
TELEMETRY_S3_ACCESS_KEY_ID=$(quote_env_value "${TELEMETRY_S3_ACCESS_KEY_ID:-}")
TELEMETRY_S3_SECRET_ACCESS_KEY=$(quote_env_value "${TELEMETRY_S3_SECRET_ACCESS_KEY:-}")
TELEMETRY_OTLP_ENDPOINT=$(quote_env_value "${TELEMETRY_OTLP_ENDPOINT:-}")
TELEMETRY_OTLP_HOST=$(quote_env_value "$telemetry_otlp_host")
TELEMETRY_OTLP_PORT=$(quote_env_value "$telemetry_otlp_port")
TELEMETRY_OTLP_LOGS_URI=$(quote_env_value "$telemetry_otlp_logs_uri")
TELEMETRY_OTLP_TLS=$(quote_env_value "$telemetry_otlp_tls")
EOF
set_file_permissions 0640 root fluent-bit "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/fluent-bit.env"

# Render fluent-bit config file
template="/opt/fluent-bit/etc/fluent-bit.template.yml"
output="/opt/fluent-bit/etc/fluent-bit.yml"
[ -f "${PODPLANE_ROOT:-}$template" ] || fatal "missing ${PODPLANE_ROOT:-}$template"
tmp="${output}.tmp"
awk \
  -v allowed_units="$allowed_units" \
  -v include_systemd="$([ "$allowed_units" != "|" ] && printf true || printf false)" \
  -v include_cloudinit="$include_cloudinit" \
  -v include_s3="$include_s3" \
  -v include_otlp="$include_otlp" \
  '
    /# BEGIN TELEMETRY_SYSTEMD_INPUT/ { in_systemd=1; if (include_systemd != "true") next }
    /# END TELEMETRY_SYSTEMD_INPUT/ { if (include_systemd != "true") { in_systemd=0; next } }
    in_systemd && include_systemd != "true" { next }
    in_systemd && /_SYSTEMD_UNIT=/ {
      unit=$0
      sub(/^.*_SYSTEMD_UNIT=/, "", unit)
      sub(/[[:space:]]*$/, "", unit)
      if (index(allowed_units, "|" unit "|") == 0) next
    }
    /# BEGIN TELEMETRY_LOG_CLOUDINIT_INPUT/ { in_cloudinit=1; if (include_cloudinit != "true") next }
    /# END TELEMETRY_LOG_CLOUDINIT_INPUT/ { if (include_cloudinit != "true") { in_cloudinit=0; next } }
    in_cloudinit && include_cloudinit != "true" { next }
    /# BEGIN TELEMETRY_S3_OUTPUT/ { in_s3=1; if (include_s3 != "true") next }
    /# END TELEMETRY_S3_OUTPUT/ { if (include_s3 != "true") { in_s3=0; next } }
    in_s3 && include_s3 != "true" { next }
    /# BEGIN TELEMETRY_OTLP_OUTPUT/ { in_otlp=1; if (include_otlp != "true") next }
    /# END TELEMETRY_OTLP_OUTPUT/ { if (include_otlp != "true") { in_otlp=0; next } }
    in_otlp && include_otlp != "true" { next }
    { print }
  ' "${PODPLANE_ROOT:-}$template" > "${PODPLANE_ROOT:-}$tmp"
set_file_permissions 0600 fluent-bit fluent-bit "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}$output"
log "wrote /opt/env/fluent-bit.env and ${output}"
