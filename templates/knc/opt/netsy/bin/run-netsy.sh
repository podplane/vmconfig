#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/env/netsy.env

export INSTANCE_ID
export INSTANCE_HOSTNAME
export INSTANCE_IPV4

export NETSY_CONFIG
export NETSY_NODE_ID
export NETSY_BIND_CLIENT
export NETSY_ADVERTISE_CLIENT
export NETSY_BIND_PEER
export NETSY_ADVERTISE_PEER
export NETSY_BIND_ELECTION
export NETSY_ADVERTISE_ELECTION
export NETSY_BIND_HEALTH
export NETSY_TLS_CA_CERT
export NETSY_TLS_SERVER_CERT
export NETSY_TLS_SERVER_KEY
export NETSY_TLS_CLIENT_CERT
export NETSY_TLS_CLIENT_KEY
export NETSY_DATA_DIR
export NETSY_DEBUG

if [ -n "${NETSY_REGION:-}" ]; then
  export AWS_DEFAULT_REGION="${NETSY_REGION}"
fi

if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
  export AWS_ENDPOINT_URL
fi
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_ACCESS_KEY_ID
fi
if [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  export AWS_SECRET_ACCESS_KEY
fi
if [ -n "${AWS_S3_USE_PATH_STYLE:-}" ]; then
  export AWS_S3_USE_PATH_STYLE
fi
if [ -n "${AWS_ROLE_ARN:-}" ]; then
  export AWS_ROLE_ARN
fi
if [ -n "${AWS_ROLE_SESSION_NAME:-}" ]; then
  export AWS_ROLE_SESSION_NAME
fi

exec /opt/netsy/bin/netsy
