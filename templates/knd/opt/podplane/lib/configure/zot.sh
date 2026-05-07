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
if [ "${PROVIDER_KIND:-}" = "aws" ]; then
  require_nonempty AWS_ACCOUNT_ID
  require_nonempty CLUSTER_ID
  default_s3_endpoint="s3.${PROVIDER_REGION:-}.amazonaws.com"
  REGISTRY_ENDPOINT="${REGISTRY_ENDPOINT:-$default_s3_endpoint}"
  REGISTRY_ASSUME_ROLE="arn:aws:iam::${AWS_ACCOUNT_ID}:role/podplane-${CLUSTER_ID}-registry"
fi
registry_secure=true
case "${REGISTRY_ENDPOINT:-$default_s3_endpoint}" in
  http://*) registry_secure=false ;;
esac
case "${REGISTRY_ENABLED:-true}" in
  true|false) ;;
  *) fatal "REGISTRY_ENABLED must be true or false" ;;
esac
if [ "${REGISTRY_ENABLED:-true}" = true ]; then
  require_nonempty REGISTRY_HOSTNAME
  require_nonempty REGISTRY_BUCKET
fi
case "${REGISTRY_HOSTNAME:-}" in
  *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-]*) fatal "REGISTRY_HOSTNAME contains invalid characters" ;;
esac
zot_address="127.0.0.1"
zot_host_url="https://127.0.0.1:5000"
if [ -n "${INSTANCE_IPV6:-}" ]; then
  zot_address='"[::1]"'
  zot_host_url="https://[::1]:5000"
fi

# Create zot env file
mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/zot.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
CLUSTER_ID=$(quote_env_value "${CLUSTER_ID:-}")
INSTANCE_ID=$(quote_env_value "${INSTANCE_ID:-}")
PROVIDER_KIND=$(quote_env_value "${PROVIDER_KIND:-}")
REGISTRY_ENABLED=$(quote_env_value "${REGISTRY_ENABLED:-true}")
REGISTRY_HOSTNAME=$(quote_env_value "${REGISTRY_HOSTNAME:-}")
REGISTRY_BUCKET=$(quote_env_value "${REGISTRY_BUCKET:-}")
REGISTRY_ENDPOINT=$(quote_env_value "${REGISTRY_ENDPOINT:-$default_s3_endpoint}")
REGISTRY_REGION=$(quote_env_value "${REGISTRY_REGION:-${PROVIDER_REGION:-}}")
REGISTRY_ASSUME_ROLE=$(quote_env_value "${REGISTRY_ASSUME_ROLE:-}")
REGISTRY_ACCESS_KEY_ID=$(quote_env_value "${REGISTRY_ACCESS_KEY_ID:-}")
REGISTRY_SECRET_ACCESS_KEY=$(quote_env_value "${REGISTRY_SECRET_ACCESS_KEY:-}")
AWS_S3_USE_PATH_STYLE=$(quote_env_value "${AWS_S3_USE_PATH_STYLE:-}")
EOF
set_file_permissions 0640 root zot "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/zot.env"
log "wrote /opt/env/zot.env"

# Create zot config file
mkdir -p "${PODPLANE_ROOT:-}/opt/zot/etc" "${PODPLANE_ROOT:-}/opt/zot/storage"
tmp="/opt/zot/etc/zot.yml.tmp"
{
  cat <<EOF
distSpecVersion: 1.1.0
storage:
  rootDirectory: /opt/zot/storage
  dedupe: false
  storageDriver:
EOF
  if [ "${PROVIDER_KIND:-}" = "google" ]; then
    cat <<EOF
    name: gcs
    bucket: ${REGISTRY_BUCKET:-}
EOF
  else
    cat <<EOF
    name: s3
    region: ${REGISTRY_REGION:-${PROVIDER_REGION:-}}
    bucket: ${REGISTRY_BUCKET:-}
    secure: ${registry_secure}
    skipverify: false
EOF
    if [ -n "${AWS_S3_USE_PATH_STYLE:-}" ]; then
      cat <<EOF
    forcepathstyle: ${AWS_S3_USE_PATH_STYLE}
EOF
    fi
    if [ -n "${REGISTRY_ENDPOINT:-$default_s3_endpoint}" ]; then
      cat <<EOF
    regionendpoint: ${REGISTRY_ENDPOINT:-$default_s3_endpoint}
EOF
    fi
  fi
  cat <<EOF
http:
  address: ${zot_address}
  port: "5000"
  tls:
    cert: /opt/crt/registry.server.crt
    key: /opt/key/registry/registry.server.key
    cacert: /opt/crt/ca.crt
  auth:
    mtls:
      identityAttributes:
        - CommonName
  accessControl:
    repositories:
      "**":
        policies:
          - users:
              - containerd.client
            actions:
              - read
log:
  level: info
EOF
} > "${PODPLANE_ROOT:-}$tmp"
set_file_permissions 0640 root zot "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/zot/etc/zot.yml"
log "wrote /opt/zot/etc/zot.yml"

if [ "${REGISTRY_ENABLED:-true}" = true ]; then
  hosts_dir="/etc/containerd/certs.d/${REGISTRY_HOSTNAME}"
  mkdir -p "${PODPLANE_ROOT:-}$hosts_dir"
  tmp="${hosts_dir}/hosts.toml.tmp"
  cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
[host."${zot_host_url}"]
  capabilities = ["pull", "resolve"]
  ca = "/opt/crt/ca.crt"
  client = [["/opt/crt/containerd.client.crt", "/opt/key/containerd/containerd.client.key"]]
EOF
  set_file_permissions 0644 root root "$tmp"
  mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}${hosts_dir}/hosts.toml"
  log "wrote ${hosts_dir}/hosts.toml"
elif [ -n "${REGISTRY_HOSTNAME:-}" ]; then
  rm -f "${PODPLANE_ROOT:-}/etc/containerd/certs.d/${REGISTRY_HOSTNAME}/hosts.toml"
fi
