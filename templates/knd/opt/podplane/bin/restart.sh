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

log "restarting systemd services..."
systemctl daemon-reload

systemctl enable nstance-recv-watch.service
systemctl enable nstance-recv-watch.path
systemctl start nstance-recv-watch.path
systemctl enable hosts-refresh.timer
systemctl start hosts-refresh.timer

if fluent_bit_enabled; then
  systemctl enable fluent-bit
  systemctl restart fluent-bit
else
  systemctl disable fluent-bit || true
  systemctl stop fluent-bit || true
fi

if zot_enabled; then
  systemctl enable zot
  systemctl restart zot
else
  systemctl disable zot || true
  systemctl stop zot || true
fi

systemctl enable containerd
systemctl restart containerd
systemctl enable nstance-agent
systemctl restart nstance-agent

if netsy_enabled; then
  systemctl enable netsy
  systemctl restart netsy
fi

if kube_apiserver_enabled; then
  systemctl enable kube-apiserver
  systemctl restart kube-apiserver
fi

if kube_controller_manager_enabled; then
  systemctl enable kube-controller-manager
fi

if kube_scheduler_enabled; then
  systemctl enable kube-scheduler
fi

if kube2iam_enabled; then
  systemctl enable kube2iam
  systemctl restart kube2iam
else
  systemctl disable kube2iam || true
  systemctl stop kube2iam || true
fi

systemctl enable kubelet
log "done restarting systemd services."
