#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Load shared helpers.
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
if { [ -n "${REGISTRY_ACCESS_KEY_ID:-}" ] && [ -z "${REGISTRY_SECRET_ACCESS_KEY:-}" ]; } ||
  { [ -z "${REGISTRY_ACCESS_KEY_ID:-}" ] && [ -n "${REGISTRY_SECRET_ACCESS_KEY:-}" ]; }; then
  fatal "REGISTRY_ACCESS_KEY_ID and REGISTRY_SECRET_ACCESS_KEY must be set together"
fi

case "${PROVIDER_KIND:-}" in
  google) registry_provider=gcs ;;
  aws|local|proxmox) registry_provider=s3 ;;
  *) fatal "PROVIDER_KIND must be one of: local, aws, google, proxmox" ;;
esac

aws_profile=""
aws_config_file=""
aws_dualstack=""
if [ "${PROVIDER_KIND:-}" = aws ]; then
  aws_dualstack=true
  if [ -n "${REGISTRY_ASSUME_ROLE:-}" ]; then
    require_nonempty INSTANCE_ID
    aws_profile=registry
    aws_config_file=/opt/registry/etc/aws-config
    tmp="${aws_config_file}.tmp"
    cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
[profile registry]
role_arn = ${REGISTRY_ASSUME_ROLE}
credential_source = Ec2InstanceMetadata
role_session_name = ${INSTANCE_ID}-registry
region = ${REGISTRY_REGION:-${PROVIDER_REGION:-}}
EOF
    set_file_permissions 0600 registry registry "$tmp"
    mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}$aws_config_file"
  else
    rm -f "${PODPLANE_ROOT:-}/opt/registry/etc/aws-config"
  fi
fi

# Create registry env file
mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/registry.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
REGISTRY_LISTEN='127.0.0.1:5000'
REGISTRY_PROVIDER=$(quote_env_value "$registry_provider")
REGISTRY_BUCKET=$(quote_env_value "${REGISTRY_BUCKET:-}")
REGISTRY_S3_ENDPOINT=$(quote_env_value "${REGISTRY_ENDPOINT:-}")
REGISTRY_S3_PATH_STYLE=$(quote_env_value "${AWS_S3_USE_PATH_STYLE:-}")
AWS_REGION=$(quote_env_value "${REGISTRY_REGION:-${PROVIDER_REGION:-}}")
AWS_PROFILE=$(quote_env_value "$aws_profile")
AWS_CONFIG_FILE=$(quote_env_value "$aws_config_file")
AWS_USE_DUALSTACK_ENDPOINT=$(quote_env_value "$aws_dualstack")
AWS_ACCESS_KEY_ID=$(quote_env_value "${REGISTRY_ACCESS_KEY_ID:-}")
AWS_SECRET_ACCESS_KEY=$(quote_env_value "${REGISTRY_SECRET_ACCESS_KEY:-}")
EOF
set_file_permissions 0600 registry registry "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/registry.env"
log "wrote /opt/env/registry.env"

if [ "${REGISTRY_ENABLED:-true}" = true ]; then
  hosts_dir="/etc/containerd/certs.d/${REGISTRY_HOSTNAME}"
  mkdir -p "${PODPLANE_ROOT:-}$hosts_dir"
  tmp="${hosts_dir}/hosts.toml.tmp"
  cat > "${PODPLANE_ROOT:-}$tmp" <<'EOF'
[host."http://127.0.0.1:5000"]
  capabilities = ["pull", "resolve"]
EOF
  set_file_permissions 0644 root root "$tmp"
  mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}${hosts_dir}/hosts.toml"
  log "wrote ${hosts_dir}/hosts.toml"
elif [ -n "${REGISTRY_HOSTNAME:-}" ]; then
  rm -f "${PODPLANE_ROOT:-}/etc/containerd/certs.d/${REGISTRY_HOSTNAME}/hosts.toml"
fi
