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

log "restarting systemd services..."
systemctl_logged daemon-reload

systemctl_logged enable nstance-recv-watch.service
systemctl_logged enable nstance-recv-watch.path
systemctl_logged start nstance-recv-watch.path
systemctl_logged enable hosts-refresh.timer
systemctl_logged start hosts-refresh.timer

if fluent_bit_enabled; then
  systemctl_logged enable fluent-bit
  systemctl_logged restart fluent-bit
else
  systemctl_logged_optional disable fluent-bit
  systemctl_logged_optional stop fluent-bit
fi

if zot_enabled; then
  systemctl_logged enable zot
  systemctl_logged restart zot
else
  systemctl_logged_optional disable zot
  systemctl_logged_optional stop zot
fi

systemctl_logged enable containerd
systemctl_logged restart containerd
systemctl_logged enable nstance-agent
systemctl_logged restart nstance-agent

if netsy_enabled; then
  systemctl_logged enable netsy
  systemctl_logged restart netsy
fi

if kube_apiserver_enabled; then
  systemctl_logged enable kube-apiserver
  systemctl_logged restart kube-apiserver
fi

if kube_controller_manager_enabled; then
  systemctl_logged enable kube-controller-manager
fi

if kube_scheduler_enabled; then
  systemctl_logged enable kube-scheduler
fi

if kube2iam_enabled; then
  systemctl_logged enable kube2iam
  systemctl_logged restart kube2iam
else
  systemctl_logged_optional disable kube2iam
  systemctl_logged_optional stop kube2iam
fi

systemctl_logged enable kubelet
log "done restarting systemd services."
