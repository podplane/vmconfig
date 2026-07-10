#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
#
# bootstrap.sh - first-boot vmconfig bootstrap.
#
# This script is intentionally one-shot. It detects immutable VM-local facts,
# writes /opt/podplane/etc/detected.env, seeds /opt/podplane/etc/mutable.env,
# and writes /opt/podplane/bootstrap.done last. Re-runnable configuration belongs
# in configure.sh.

set -euo pipefail

USER_DATA_ENV="/opt/podplane/etc/user-data.env"
DETECTED_ENV="/opt/podplane/etc/detected.env"
MUTABLE_ENV="/opt/podplane/etc/mutable.env"
BOOTSTRAP_ENV="/opt/podplane/etc/bootstrap.env"
DEFAULT_MUTABLE_ENV="/opt/podplane/share/defaults/mutable.env"
BOOTSTRAP_DONE="/opt/podplane/bootstrap.done"
INSTALLED_VMCONFIG_MANIFEST="/opt/podplane/share/vmconfig-installed.json"

# load helpers
SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/helpers.sh"

# preflight checks
[ "$(id -u)" = "0" ] || fatal "must be run as root"
[ -f "${PODPLANE_ROOT:-}$USER_DATA_ENV" ] || fatal "missing ${USER_DATA_ENV}"
[ -f "${PODPLANE_ROOT:-}$DEFAULT_MUTABLE_ENV" ] || fatal "missing ${DEFAULT_MUTABLE_ENV}"
[ -f "${PODPLANE_ROOT:-}$INSTALLED_VMCONFIG_MANIFEST" ] || fatal "missing ${INSTALLED_VMCONFIG_MANIFEST}"
if [ -f "${PODPLANE_ROOT:-}$BOOTSTRAP_DONE" ]; then
  log "${BOOTSTRAP_DONE} already exists; nothing to do."
  exit 0
fi

# load and check userdata.env file
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}$USER_DATA_ENV"
if [ -z "${VMCONFIG_KIND:-}" ]; then
  load_vmconfig_kind "${PODPLANE_ROOT:-}$INSTALLED_VMCONFIG_MANIFEST"
fi
case "$VMCONFIG_KIND" in
  knd|knc) ;;
  *) fatal "unsupported vmconfig.kind in ${INSTALLED_VMCONFIG_MANIFEST}: '${VMCONFIG_KIND}'" ;;
esac
case "${PROVIDER_KIND:-}" in
  local|aws|google|proxmox) ;;
  *) fatal "PROVIDER_KIND must be one of: local, aws, google, proxmox" ;;
esac
if [ "${PROVIDER_KIND}" = "aws" ]; then
  require_nonempty AWS_ACCOUNT_ID
  require_nonempty CLUSTER_ID
fi
if [ "${PROVIDER_KIND}" = "google" ]; then
  require_nonempty GOOGLE_PROJECT_ID
fi

# write detected.env file
log "detecting immutable VM facts..."
instance_provider_id="${INSTANCE_PROVIDER_ID:-$(derive_instance_provider_id)}"
instance_netdev="${INSTANCE_NETDEV:-$(ip route get 1 | awk '{print $5; exit}')}"
[ -n "$instance_netdev" ] || fatal "cannot determine instance primary network interface device"
instance_ipv4="${INSTANCE_IPV4:-$(ip -4 addr show dev "$instance_netdev" | awk '/inet / {print $2; exit}' | cut -d/ -f1)}"
[ -n "$instance_ipv4" ] || fatal "cannot determine instance IPv4 address"
instance_ipv6="${INSTANCE_IPV6-$(ip -6 addr show dev "$instance_netdev" | awk '/inet6 / && !/fe80/ {print $2; exit}' | cut -d/ -f1)}"
instance_hostname="${INSTANCE_HOSTNAME:-$(hostname -s)}"
instance_fqdn="${INSTANCE_FQDN:-$(derive_instance_fqdn "$instance_hostname")}"
tmp_detected="${DETECTED_ENV}.tmp"
tmp_mutable="${MUTABLE_ENV}.tmp"
tmp_done="${BOOTSTRAP_DONE}.tmp"
rm -f "${PODPLANE_ROOT:-}$tmp_detected" "${PODPLANE_ROOT:-}$BOOTSTRAP_ENV" "${PODPLANE_ROOT:-}$tmp_mutable" "${PODPLANE_ROOT:-}$tmp_done"
log "writing ${DETECTED_ENV}..."
cat > "${PODPLANE_ROOT:-}$tmp_detected" <<EOF
VMCONFIG_KIND=$(quote_env_value "${VMCONFIG_KIND:-}")
VMCONFIG_BASE_KIND=$(quote_env_value node)
INSTANCE_PROVIDER_ID=$(quote_env_value "$instance_provider_id")
INSTANCE_IPV4=$(quote_env_value "$instance_ipv4")
INSTANCE_IPV6=$(quote_env_value "$instance_ipv6")
INSTANCE_NETDEV=$(quote_env_value "$instance_netdev")
INSTANCE_HOSTNAME=$(quote_env_value "$instance_hostname")
INSTANCE_FQDN=$(quote_env_value "$instance_fqdn")
EOF
[ -s "${PODPLANE_ROOT:-}$tmp_detected" ] || fatal "failed to write non-empty ${DETECTED_ENV}"
set_file_permissions 0600 root root "$tmp_detected"

# write bootstrap.env file
# this is used to bootstrap the initial mutable.env file with a subset of user-data.env vars
log "writing ${BOOTSTRAP_ENV}..."
grep -E '^SSH_AUTHORIZED_KEY=' \
  "${PODPLANE_ROOT:-}$USER_DATA_ENV" > "${PODPLANE_ROOT:-}$BOOTSTRAP_ENV"
[ -s "${PODPLANE_ROOT:-}$BOOTSTRAP_ENV" ] || fatal "failed to write non-empty ${BOOTSTRAP_ENV}"
set_file_permissions 0600 root root "$BOOTSTRAP_ENV"

# write mutable.env file
# layer the bootstrap.env file over the default mutable.env file to bootstrap the first mutable.env file version
log "writing ${MUTABLE_ENV}..."
cp "${PODPLANE_ROOT:-}$DEFAULT_MUTABLE_ENV" "${PODPLANE_ROOT:-}$tmp_mutable"
UPDATE_MUTABLE_ENV_REFRESH_HOSTS=false \
  "${SCRIPT_DIR}/update-mutable-env.sh" \
  "${PODPLANE_ROOT:-}$BOOTSTRAP_ENV" \
  "${PODPLANE_ROOT:-}$tmp_mutable" \
  true
[ -s "${PODPLANE_ROOT:-}$tmp_mutable" ] || fatal "failed to write non-empty ${MUTABLE_ENV}"
set_file_permissions 0600 root root "$tmp_mutable"

# finalise
printf 'completed_at=%s\n' "$(date -u +%FT%TZ)" > "${PODPLANE_ROOT:-}$tmp_done"
[ -s "${PODPLANE_ROOT:-}$tmp_done" ] || fatal "failed to write non-empty ${BOOTSTRAP_DONE}"
set_file_permissions 0600 root root "$tmp_done"
mv "${PODPLANE_ROOT:-}$tmp_detected" "${PODPLANE_ROOT:-}$DETECTED_ENV"
mv "${PODPLANE_ROOT:-}$tmp_mutable" "${PODPLANE_ROOT:-}$MUTABLE_ENV"
mv "${PODPLANE_ROOT:-}$tmp_done" "${PODPLANE_ROOT:-}$BOOTSTRAP_DONE"
log "bootstrap.sh completed successfully."
