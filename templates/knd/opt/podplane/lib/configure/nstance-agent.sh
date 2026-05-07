#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Load helpers
SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../helpers.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../features.sh"

# Load env files
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/detected.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/mutable.env"
case "$VMCONFIG_KIND" in
  knd|knc) ;;
  *) fatal "VMCONFIG_KIND must be one of: knd, knc" ;;
esac
case "${TELEMETRY_ENABLED:-false}" in
  true|false) ;;
  *) fatal "TELEMETRY_ENABLED must be true or false" ;;
esac
case "${TELEMETRY_LOG_CLOUDINIT:-true}" in
  true|false) ;;
  *) fatal "TELEMETRY_LOG_CLOUDINIT must be true or false" ;;
esac

require_nonempty NSTANCE_SERVER_REGISTRATION_ADDR
require_nonempty NSTANCE_SERVER_AGENT_ADDR

# Create nstance-agent env file
mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/nstance-agent.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
NSTANCE_SERVER_REGISTRATION_ADDR=$(quote_env_value "$NSTANCE_SERVER_REGISTRATION_ADDR")
NSTANCE_SERVER_AGENT_ADDR=$(quote_env_value "$NSTANCE_SERVER_AGENT_ADDR")
NSTANCE_IDENTITY_DIR=$(quote_env_value /opt/nstance-agent/identity)
NSTANCE_KEYS_DIR=$(quote_env_value /opt/nstance-agent/keys)
NSTANCE_RECV_DIR=$(quote_env_value /opt/nstance-agent/recv)
NSTANCE_IDENTITY_MODE=$(quote_env_value 0600)
NSTANCE_KEYS_MODE=$(quote_env_value 0640)
NSTANCE_RECV_MODE=$(quote_env_value 0600)
NSTANCE_INSTANCE_KIND=$(quote_env_value "${VMCONFIG_KIND:-}")
NSTANCE_INSTANCE_ID=$(quote_env_value "${INSTANCE_ID:-}")
NSTANCE_INSTANCE_HOSTNAME=$(quote_env_value "${INSTANCE_HOSTNAME:-}")
NSTANCE_INSTANCE_FQDN=$(quote_env_value "${INSTANCE_FQDN:-}")
NSTANCE_INSTANCE_IPV4=$(quote_env_value "${INSTANCE_IPV4:-}")
NSTANCE_INSTANCE_IPV6=$(quote_env_value "${INSTANCE_IPV6:-}")
NSTANCE_METRICS_INTERVAL=$(quote_env_value 60s)
NSTANCE_SPOT_POLL_INTERVAL=$(quote_env_value 2s)
EOF
set_file_permissions 0640 root nstance-agent "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/nstance-agent.env"
log "wrote /opt/env/nstance-agent.env"
