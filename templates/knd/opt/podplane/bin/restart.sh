#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

INSTALLED_VMCONFIG_MANIFEST="/opt/podplane/share/vmconfig-installed.json"

# Load helpers
SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/helpers.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/features.sh"

# Load env files
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/detected.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/mutable.env"

# Set vars
load_vmconfig_kind "${PODPLANE_ROOT:-}$INSTALLED_VMCONFIG_MANIFEST"
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

systemctl_logged() {
  log "systemctl $*"
  systemctl "$@"
  log "systemctl $* done"
}

systemctl_logged_optional() {
  if ! systemctl_logged "$@"; then
    log "systemctl $* failed; continuing."
  fi
}

enable_units=(
  nstance-recv-watch.service
  nstance-recv-watch.path
  hosts-refresh.timer
  containerd
  nstance-agent
  kubelet
)
start_units=(
  nstance-recv-watch.path
  hosts-refresh.timer
)
restart_units=(
  containerd
  nstance-agent
)
disable_units=()
stop_units=()

if fluent_bit_enabled; then
  enable_units+=(fluent-bit)
  restart_units+=(fluent-bit)
else
  disable_units+=(fluent-bit)
  stop_units+=(fluent-bit)
fi

if zot_enabled; then
  enable_units+=(zot)
  restart_units+=(zot)
else
  disable_units+=(zot)
  stop_units+=(zot)
fi

if netsy_enabled; then
  enable_units+=(netsy)
  restart_units+=(netsy)
fi

if kube_apiserver_enabled; then
  enable_units+=(kube-apiserver)
  restart_units+=(kube-apiserver)
fi

if kube_controller_manager_enabled; then
  enable_units+=(kube-controller-manager)
fi

if kube_scheduler_enabled; then
  enable_units+=(kube-scheduler)
fi

if kube2iam_enabled; then
  enable_units+=(kube2iam)
  restart_units+=(kube2iam)
else
  disable_units+=(kube2iam)
  stop_units+=(kube2iam)
fi

log "restarting systemd services..."
systemctl_logged daemon-reload
if [ "${#disable_units[@]}" -gt 0 ]; then
  systemctl_logged_optional disable "${disable_units[@]}"
fi
if [ "${#stop_units[@]}" -gt 0 ]; then
  systemctl_logged_optional stop "${stop_units[@]}"
fi
systemctl_logged enable "${enable_units[@]}"
systemctl_logged start "${start_units[@]}"
systemctl_logged restart "${restart_units[@]}"
log "done restarting systemd services."
