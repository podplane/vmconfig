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
NETSY_CONFIG_PATH="/opt/netsy/etc/cluster.jsonc"
NETSY_STORAGE_PROVIDER="s3"
if [ "${PROVIDER_KIND:-}" = "google" ]; then
  NETSY_STORAGE_PROVIDER="gcs"
fi
require_nonempty CLUSTER_ID
require_nonempty NETSY_BUCKET
require_nonempty INSTANCE_ID
require_nonempty INSTANCE_IPV4

# Create netsy config file
mkdir -p "${PODPLANE_ROOT:-}/opt/netsy/etc"
tmp="${NETSY_CONFIG_PATH}.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
{
  "cluster_id": $(json_string "$CLUSTER_ID"),
  "storage": {
    "provider": $(json_string "$NETSY_STORAGE_PROVIDER"),
    "bucket_name": $(json_string "$NETSY_BUCKET"),
    "key_prefix": $(json_string "${NETSY_KEY_PREFIX:-}"),
    "class": "STANDARD",
    "encryption": "provider-managed"
  },
  "heartbeat_interval": "1s",
  "elector": {
    "degradation_count": 2,
    "deregistration_timeout": "3m",
    "primary_prior_timeout": "5s"
  },
  "replication": {
    "quorum": -1,
    "degradation_count": 2,
    "chunk_buffer": {
      "threshold_size_mb": 4,
      "threshold_age_minutes": 1
    }
  },
  "snapshot": {
    "threshold_records": 10000,
    "threshold_size_mb": 10000,
    "threshold_age_minutes": 0
  },
  "compaction_interval": "5m"
}
EOF
set_file_permissions 0640 root netsy "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}$NETSY_CONFIG_PATH"

# Create netsy env file
mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/netsy.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
INSTANCE_ID=$(quote_env_value "${INSTANCE_ID:-}")
INSTANCE_HOSTNAME=$(quote_env_value "${INSTANCE_HOSTNAME:-}")
INSTANCE_IPV4=$(quote_env_value "${INSTANCE_IPV4:-}")
NETSY_CONFIG=$(quote_env_value "$NETSY_CONFIG_PATH")
NETSY_NODE_ID=$(quote_env_value "${INSTANCE_ID:-}")
NETSY_BIND_CLIENT=$(quote_env_value "0.0.0.0:2378")
NETSY_ADVERTISE_CLIENT=$(quote_env_value "${INSTANCE_IPV4:-}:2378")
NETSY_BIND_PEER=$(quote_env_value "0.0.0.0:2381")
NETSY_ADVERTISE_PEER=$(quote_env_value "${INSTANCE_IPV4:-}:2381")
NETSY_BIND_ELECTION=$(quote_env_value "0.0.0.0:8443")
NETSY_ADVERTISE_ELECTION=$(quote_env_value "${INSTANCE_IPV4:-}:8443")
NETSY_BIND_HEALTH=$(quote_env_value "0.0.0.0:8080")
NETSY_TLS_CA_CERT=$(quote_env_value "/opt/crt/ca.crt")
NETSY_TLS_SERVER_CERT=$(quote_env_value "/opt/crt/netsy.server.crt")
NETSY_TLS_SERVER_KEY=$(quote_env_value "/opt/key/netsy/netsy.server.key")
NETSY_TLS_CLIENT_CERT=$(quote_env_value "/opt/crt/netsy.client.crt")
NETSY_TLS_CLIENT_KEY=$(quote_env_value "/opt/key/netsy/netsy.client.key")
NETSY_DATA_DIR=$(quote_env_value "/opt/data")
NETSY_DEBUG=false
NETSY_REGION=$(quote_env_value "${NETSY_REGION:-${PROVIDER_REGION:-}}")
EOF
if [ "${PROVIDER_KIND:-}" = "local" ] || [ "${PROVIDER_KIND:-}" = "proxmox" ]; then
  cat >> "${PODPLANE_ROOT:-}$tmp" <<EOF
AWS_ENDPOINT_URL=$(quote_env_value "${NETSY_ENDPOINT:-}")
AWS_ACCESS_KEY_ID=$(quote_env_value "${NETSY_ACCESS_KEY_ID:-}")
AWS_SECRET_ACCESS_KEY=$(quote_env_value "${NETSY_SECRET_ACCESS_KEY:-}")
AWS_S3_USE_PATH_STYLE=true
EOF
elif [ "${PROVIDER_KIND:-}" = "aws" ]; then
  require_nonempty AWS_ACCOUNT_ID
  netsy_assume_role="${NETSY_ASSUME_ROLE:-arn:aws:iam::${AWS_ACCOUNT_ID}:role/podplane-${CLUSTER_ID}-netsy}"
  cat >> "${PODPLANE_ROOT:-}$tmp" <<EOF
AWS_ROLE_ARN=$(quote_env_value "$netsy_assume_role")
AWS_ROLE_SESSION_NAME=$(quote_env_value "${INSTANCE_ID:-}-netsy")
EOF
fi
set_file_permissions 0640 root netsy "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/netsy.env"
log "wrote ${NETSY_CONFIG_PATH} and /opt/env/netsy.env"
