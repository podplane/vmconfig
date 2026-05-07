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
case "$VMCONFIG_KIND" in
  knd|knc) ;;
  *) fatal "VMCONFIG_KIND must be one of: knd, knc" ;;
esac

KUBE_APISERVER_INTERNAL_HOSTNAME="kube-apiserver.podplane.internal"
KUBE_APISERVER_HOSTS_BEGIN="# BEGIN podplane managed kube-apiserver"
KUBE_APISERVER_HOSTS_END="# END podplane managed kube-apiserver"

# Replaces the managed kube-apiserver /etc/hosts block with the given entries.
write_kube_apiserver_hosts_block() { # <entry>...
  local hosts_file="${PODPLANE_ROOT:-}/etc/hosts"
  local tmp_file="${hosts_file}.tmp"

  mkdir -p "$(dirname "$hosts_file")"
  touch "$hosts_file"
  awk \
    -v begin="$KUBE_APISERVER_HOSTS_BEGIN" \
    -v end="$KUBE_APISERVER_HOSTS_END" \
    '$0 == begin {skip=1; next} $0 == end {skip=0; next} !skip {print}' \
    "$hosts_file" > "$tmp_file"
  {
    cat "$tmp_file"
    printf '%s\n' "$KUBE_APISERVER_HOSTS_BEGIN"
    printf '%s\n' "$@"
    printf '%s\n' "$KUBE_APISERVER_HOSTS_END"
  } > "$hosts_file"
  rm -f "$tmp_file"
}

# Removes the managed kube-apiserver /etc/hosts block if it exists.
remove_kube_apiserver_hosts_block() {
  local hosts_file="${PODPLANE_ROOT:-}/etc/hosts"
  local tmp_file="${hosts_file}.tmp"

  [ -f "$hosts_file" ] || return 0
  awk \
    -v begin="$KUBE_APISERVER_HOSTS_BEGIN" \
    -v end="$KUBE_APISERVER_HOSTS_END" \
    '$0 == begin {skip=1; next} $0 == end {skip=0; next} !skip {print}' \
    "$hosts_file" > "$tmp_file"
  mv "$tmp_file" "$hosts_file"
}

# Map the fixed internal kube-apiserver name to the local API or configured LB.
if [ "$VMCONFIG_KIND" = "knc" ]; then
  write_kube_apiserver_hosts_block "127.0.0.1 ${KUBE_APISERVER_INTERNAL_HOSTNAME}"
  log "mapped ${KUBE_APISERVER_INTERNAL_HOSTNAME} to local kube-apiserver"
elif [ -z "${KUBE_API_INTERNAL_LB_HOSTNAME:-}" ]; then
  remove_kube_apiserver_hosts_block
  log "removed ${KUBE_APISERVER_INTERNAL_HOSTNAME} hosts mapping"
else
  # Resolve the configured API load balancer and pin the fixed internal name to its IPs.
  command -v getent >/dev/null 2>&1 || fatal "required tool missing: getent"
  mapfile -t kube_apiserver_ips < <(getent ahosts "$KUBE_API_INTERNAL_LB_HOSTNAME" | awk '{print $1}' | sort -u)
  [ "${#kube_apiserver_ips[@]}" -gt 0 ] || fatal "failed to resolve KUBE_API_INTERNAL_LB_HOSTNAME=${KUBE_API_INTERNAL_LB_HOSTNAME}"

  entries=()
  for ip in "${kube_apiserver_ips[@]}"; do
    entries+=("${ip} ${KUBE_APISERVER_INTERNAL_HOSTNAME}")
  done
  write_kube_apiserver_hosts_block "${entries[@]}"
  log "mapped ${KUBE_APISERVER_INTERNAL_HOSTNAME} to ${KUBE_API_INTERNAL_LB_HOSTNAME}"
fi
