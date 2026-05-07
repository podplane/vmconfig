#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/env/nstance-agent.env

args=(
)

export NSTANCE_SERVER_REGISTRATION_ADDR
export NSTANCE_SERVER_AGENT_ADDR
export NSTANCE_IDENTITY_DIR
export NSTANCE_KEYS_DIR
export NSTANCE_RECV_DIR
export NSTANCE_IDENTITY_MODE
export NSTANCE_KEYS_MODE
export NSTANCE_RECV_MODE
export NSTANCE_INSTANCE_KIND
export NSTANCE_INSTANCE_ID
export NSTANCE_INSTANCE_HOSTNAME
export NSTANCE_INSTANCE_FQDN
export NSTANCE_INSTANCE_IPV4
export NSTANCE_INSTANCE_IPV6
export NSTANCE_METRICS_INTERVAL
export NSTANCE_SPOT_POLL_INTERVAL

exec /opt/nstance-agent/bin/nstance-agent "${args[@]}"
