#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
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

containerd_config="/etc/containerd/config.toml"
vmconfig_manifest="/opt/podplane/share/vmconfig-installed.json"
sandbox_images="$({ sed -n 's/.*"image":[[:space:]]*"\(registry\.k8s\.io\/pause:[^"]*\)".*/\1/p' "${PODPLANE_ROOT:-}$vmconfig_manifest" 2>/dev/null || true; } | sort -u)"
sandbox_count="$(printf '%s\n' "$sandbox_images" | sed '/^$/d' | wc -l | tr -d ' ')"
case "$sandbox_count" in
  0) fatal "vmconfig manifest does not define a registry.k8s.io/pause runtime image" ;;
  1) ;;
  *) fatal "vmconfig manifest defines multiple registry.k8s.io/pause runtime images: ${sandbox_images}" ;;
esac
sandbox_image="$sandbox_images"

if [ "${REGISTRY_ENABLED:-true}" = true ] && [ -n "${REGISTRY_HOSTNAME:-}" ]; then
  sandbox_image="${REGISTRY_HOSTNAME}/mirror/${sandbox_image}"
fi

tmp="${containerd_config}.tmp"
awk -v sandbox_image="$sandbox_image" '
  /^  \[plugins\."io\.containerd\.cri\.v1\.images"\]$/ {
    print
    print "    [plugins.\"io.containerd.cri.v1.images\".pinned_images]"
    print "      sandbox = \"" sandbox_image "\""
    in_images = 1
    in_pinned_images = 0
    next
  }
  /^  \[plugins\./ {
    in_images = 0
    in_pinned_images = 0
  }
  in_images && /^    \[plugins\."io\.containerd\.cri\.v1\.images"\.pinned_images\]$/ {
    in_pinned_images = 1
    next
  }
  in_images && /^[[:space:]]*sandbox_image[[:space:]]*=/ {
    next
  }
  in_images && in_pinned_images && /^[[:space:]]*sandbox[[:space:]]*=/ {
    next
  }
  { print }
' "${PODPLANE_ROOT:-}$containerd_config" > "${PODPLANE_ROOT:-}$tmp"
set_file_permissions 0644 root root "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}$containerd_config"
log "configured containerd sandbox image ${sandbox_image}"
