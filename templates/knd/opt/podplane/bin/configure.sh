#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
#
# configure.sh - configure the system on every boot.
#
# Invoked by user-data after install.sh has completed. Required to be
# idempotent and fault-tolerant: re-runs after partial completion (e.g. a
# kernel panic mid-run) must converge to the same end state.
#
# Instance kind is read from /opt/podplane/share/vmconfig-installed.json.
# First-boot detection and mutable env seeding are owned by bootstrap.sh.

set -euo pipefail

VMCONFIG_MANIFEST="/opt/podplane/share/vmconfig-manifest.json"
INSTALLED_VMCONFIG_MANIFEST="/opt/podplane/share/vmconfig-installed.json"
PERMISSIONS_SCRIPT="/opt/podplane/bin/permissions.sh"
BOOTSTRAP_SCRIPT="/opt/podplane/bin/bootstrap.sh"
USER_DATA_ENV="/opt/podplane/etc/user-data.env"
DETECTED_ENV="/opt/podplane/etc/detected.env"
MUTABLE_ENV="/opt/podplane/etc/mutable.env"
BOOTSTRAP_DONE="/opt/podplane/bootstrap.done"
CONFIGURE_COMPONENT_DIR="/opt/podplane/lib/configure"
HELPERS_SCRIPT="/opt/podplane/lib/helpers.sh"

# shellcheck source=/dev/null
source "$HELPERS_SCRIPT"

# preflight ------------------------------------------------------------------

# Check current user is root
[ "$(id -u)" = "0" ] || fatal "must be run as root"

# Error if vmconfig manifest exists (installation is not complete)
if [ -f "$VMCONFIG_MANIFEST" ]; then
  fatal "install is incomplete (vmconfig manifest still exists at ${VMCONFIG_MANIFEST})"
fi

# Check vmconfig was installed
[ -f "$INSTALLED_VMCONFIG_MANIFEST" ] || fatal "missing ${INSTALLED_VMCONFIG_MANIFEST} - has install.sh run?"
[ -f "$USER_DATA_ENV" ] || fatal "missing ${USER_DATA_ENV}"
[ -x "$BOOTSTRAP_SCRIPT" ] || fatal "missing or non-executable: ${BOOTSTRAP_SCRIPT}"

# Determine instance kind from installed vmconfig manifest
load_vmconfig_kind "$INSTALLED_VMCONFIG_MANIFEST"

# permissions ----------------------------------------------------------------

if [ -x "$PERMISSIONS_SCRIPT" ]; then
  log "invoking ${PERMISSIONS_SCRIPT} ${VMCONFIG_KIND}"
  "$PERMISSIONS_SCRIPT" "$VMCONFIG_KIND"
else
  fatal "missing or non-executable: ${PERMISSIONS_SCRIPT}"
fi

# environment ----------------------------------------------------------------

if [ -f "$BOOTSTRAP_DONE" ] && { [ ! -s "$DETECTED_ENV" ] || [ ! -s "$MUTABLE_ENV" ]; }; then
  fatal "bootstrap marker exists but required env files are missing or empty"
fi

if [ ! -f "$BOOTSTRAP_DONE" ]; then
  log "invoking ${BOOTSTRAP_SCRIPT}"
  "$BOOTSTRAP_SCRIPT"
fi

log "loading ${USER_DATA_ENV}..."
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}$USER_DATA_ENV"
log "loading ${DETECTED_ENV}..."
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}$DETECTED_ENV"
log "loading ${MUTABLE_ENV}..."
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}$MUTABLE_ENV"

case "${PROVIDER_KIND:-}" in
  local|aws|google|proxmox) ;;
  *) fatal "PROVIDER_KIND must be one of: local, aws, google, proxmox" ;;
esac
case "${TELEMETRY_ENABLED:-false}" in
  true|false) ;;
  *) fatal "TELEMETRY_ENABLED must be true or false" ;;
esac
case "${TELEMETRY_LOG_CLOUDINIT:-true}" in
  true|false) ;;
  *) fatal "TELEMETRY_LOG_CLOUDINIT must be true or false" ;;
esac
case "${REGISTRY_ENABLED:-true}" in
  true|false) ;;
  *) fatal "REGISTRY_ENABLED must be true or false" ;;
esac
if [ "${PROVIDER_KIND}" = "aws" ]; then
  require_nonempty AWS_ACCOUNT_ID
  require_nonempty CLUSTER_ID
fi
if [ -n "${NSTANCE_CA_CERT:-}" ]; then
  log "writing nstance CA certificate from user-data env..."
  mkdir -p "${PODPLANE_ROOT:-}/opt/nstance-agent/identity"
  printf '%s' "${NSTANCE_CA_CERT}" | base64 -d > "${PODPLANE_ROOT:-}/opt/nstance-agent/identity/ca.crt"
fi
require_nonempty NSTANCE_SERVER_REGISTRATION_ADDR
require_nonempty NSTANCE_SERVER_AGENT_ADDR

log "Checking connectivity to nstance server..."
check_tcp_connectivity "nstance registration server" "$NSTANCE_SERVER_REGISTRATION_ADDR"
check_tcp_connectivity "nstance agent server" "$NSTANCE_SERVER_AGENT_ADDR"

log "generating component env files..."
"${CONFIGURE_COMPONENT_DIR}/hosts.sh"
"${CONFIGURE_COMPONENT_DIR}/nstance-agent.sh"
"${CONFIGURE_COMPONENT_DIR}/fluent-bit.sh"
"${CONFIGURE_COMPONENT_DIR}/containerd.sh"
"${CONFIGURE_COMPONENT_DIR}/zot.sh"
"${CONFIGURE_COMPONENT_DIR}/kube2iam.sh"
"${CONFIGURE_COMPONENT_DIR}/kube.sh"
if [ "$VMCONFIG_KIND" = "knc" ]; then
  "${CONFIGURE_COMPONENT_DIR}/netsy.sh"
fi

# runtime configuration -------------------------------------------------------

if [ ! -f /opt/nstance-agent/identity/ca.crt ]; then
  fatal "nstance CA certificate is required but missing"
fi
log "configuring nstance CA file permissions..."
chmod 0600 /opt/nstance-agent/identity/ca.crt
chown nstance-agent:nstance-agent /opt/nstance-agent/identity/ca.crt

# First boot starts with nonce.jwt and no identity.crt. nstance-agent stores
# identity.crt, then deletes nonce.jwt after registration succeeds.
if [ -f /opt/nstance-agent/identity/nonce.jwt ]; then
  log "configuring nonce file permissions..."
  chmod 0600 /opt/nstance-agent/identity/nonce.jwt
  chown nstance-agent:nstance-agent /opt/nstance-agent/identity/nonce.jwt
elif [ ! -f /opt/nstance-agent/identity/identity.crt ]; then
  fatal "nstance nonce JWT is required before registration, or identity certificate after registration"
fi

if [ -n "${SSH_AUTHORIZED_KEY:-}" ]; then
  log "ensuring SSH authorized_keys is configured..."
  mkdir -p /home/admin/.ssh
  chmod 0700 /home/admin/.ssh
  echo "${SSH_AUTHORIZED_KEY}" > /home/admin/.ssh/authorized_keys
  chmod 0600 /home/admin/.ssh/authorized_keys
  chown -R admin:admin /home/admin/.ssh
elif [ -f /home/admin/.ssh/authorized_keys ]; then
  log "removing SSH authorized_keys file..."
  rm -f /home/admin/.ssh/authorized_keys
fi

log "applying sysctl parameters..."
sysctl --system

if [ -S /var/run/containerd/containerd.sock ]; then
  log "ensuring correct permissions for containerd socket..."
  chgrp containerd /var/run/containerd/containerd.sock
fi

log "configure.sh completed successfully."
