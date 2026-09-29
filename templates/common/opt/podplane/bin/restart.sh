#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Applies the service lifecycle required by the installed vmconfig kind.

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

enable_units=()
start_units=()
restart_units=()
disable_units=()
stop_units=()

case "$VMCONFIG_KIND" in
  knd|knc)
    enable_units+=(nstance-recv-watch.service nstance-recv-watch.path hosts-refresh.timer containerd nstance-agent kubelet)
    start_units+=(nstance-recv-watch.path hosts-refresh.timer)
    restart_units+=(containerd nstance-agent)
    if nstance_counters_enabled; then
      enable_units+=(nstance-counters.service)
      restart_units+=(nstance-counters.service)
    else
      disable_units+=(nstance-counters.service)
      stop_units+=(nstance-counters.service)
    fi
    ;;
  nst)
    enable_units+=(nstance-server.service)
    restart_units+=(nstance-server.service)
    case "${NSTANCE_SLEEP_ENABLED:-}" in
      true) enable_units+=(nstance-server-proxy.service); restart_units+=(nstance-server-proxy.service) ;;
      false) disable_units+=(nstance-server-proxy.service); stop_units+=(nstance-server-proxy.service) ;;
      *) fatal "NSTANCE_SLEEP_ENABLED must be true or false" ;;
    esac
    case "${NSTANCE_TUNNEL_ENABLED:-}" in
      true)
        enable_units+=(containerd kubelet nstance-server-tunnel.service)
        restart_units+=(containerd kubelet nstance-server-tunnel.service)
        ;;
      false)
        disable_units+=(nstance-server-tunnel.service kubelet containerd)
        stop_units+=(nstance-server-tunnel.service kubelet containerd)
        ;;
      *) fatal "NSTANCE_TUNNEL_ENABLED must be true or false" ;;
    esac
    ;;
  nat)
    enable_units+=(podplane-nat.service nstance-agent nstance-recv-watch.service nstance-recv-watch.path)
    start_units+=(nstance-recv-watch.path)
    restart_units+=(podplane-nat.service nstance-agent)
    ;;
esac

if fluent_bit_enabled; then
  enable_units+=(fluent-bit)
  restart_units+=(fluent-bit)
else
  disable_units+=(fluent-bit)
  stop_units+=(fluent-bit)
fi

if [ "$VMCONFIG_KIND" = knd ] || [ "$VMCONFIG_KIND" = knc ] || [ "$VMCONFIG_KIND" = nst ]; then
  if registry_enabled; then
    enable_units+=(registry)
    restart_units+=(registry)
  else
    disable_units+=(registry)
    stop_units+=(registry)
  fi
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

if [ "$VMCONFIG_KIND" = knd ] || [ "$VMCONFIG_KIND" = knc ]; then
  if kube2iam_enabled; then
    enable_units+=(kube2iam)
    restart_units+=(kube2iam)
  else
    disable_units+=(kube2iam)
    stop_units+=(kube2iam)
  fi
fi

log "restarting systemd services..."
systemctl_logged daemon-reload
if [ "${#disable_units[@]}" -gt 0 ]; then
  systemctl_logged_optional disable "${disable_units[@]}"
fi
if [ "${#stop_units[@]}" -gt 0 ]; then
  systemctl_logged_optional stop "${stop_units[@]}"
fi
if [ "${#enable_units[@]}" -gt 0 ]; then
  systemctl_logged enable "${enable_units[@]}"
fi
if [ "${#start_units[@]}" -gt 0 ]; then
  systemctl_logged start "${start_units[@]}"
fi
if [ "${#restart_units[@]}" -gt 0 ]; then
  systemctl_logged restart "${restart_units[@]}"
fi
log "done restarting systemd services."
