#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

# Validates and writes the production ports monitored by Nstance connection counters.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../helpers.sh"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"

require_nonempty NSTANCE_EBPF_PORTS
IFS=', ' read -r -a ports <<< "$NSTANCE_EBPF_PORTS"
for port in "${ports[@]}"; do
  case "$port" in
    ''|*[!0-9]*) fatal "NSTANCE_EBPF_PORTS must contain TCP ports" ;;
  esac
  ((10#$port >= 1 && 10#$port <= 65535)) || fatal "NSTANCE_EBPF_PORTS contains invalid port $port"
done

mkdir -p "${PODPLANE_ROOT:-}/etc/nstance-counters"
printf '%s\n' "${ports[@]}" | sort -nu > "${PODPLANE_ROOT:-}/etc/nstance-counters/production-ports"
set_file_permissions 0644 root root /etc/nstance-counters/production-ports
log "configured Nstance active connection counter ports"
