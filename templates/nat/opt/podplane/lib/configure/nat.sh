#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Validates NAT settings and writes the environment consumed by nat-host.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../helpers.sh"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/detected.env"

require_nonempty NAT_IPV4_SOURCE_CIDRS
NSTANCE_METRICS_INTERFACE="${NSTANCE_METRICS_INTERFACE:-${INSTANCE_NETDEV:-}}"
require_nonempty NSTANCE_METRICS_INTERFACE
case "${NAT64_ENABLED:-false}" in
  true|false) ;;
  *) fatal "NAT64_ENABLED must be true or false" ;;
esac

tmp="/opt/podplane/etc/nat.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
NSTANCE_METRICS_INTERFACE=$(quote_env_value "$NSTANCE_METRICS_INTERFACE")
NAT_IPV4_SOURCE_CIDRS=$(quote_env_value "$NAT_IPV4_SOURCE_CIDRS")
NAT_CONNTRACK_MAX=$(quote_env_value "${NAT_CONNTRACK_MAX:-262144}")
NAT64_ENABLED=$(quote_env_value "${NAT64_ENABLED:-false}")
NAT64_PREFIX=$(quote_env_value "${NAT64_PREFIX:-64:ff9b::/96}")
NAT64_SOURCE_IPV6_CIDRS=$(quote_env_value "${NAT64_SOURCE_IPV6_CIDRS:-}")
NAT64_BLOCKED_IPV6_CIDRS=$(quote_env_value "${NAT64_BLOCKED_IPV6_CIDRS:-}")
NAT64_POOL4_ADDRESS=$(quote_env_value "${NAT64_POOL4_ADDRESS:-}")
EOF
set_file_permissions 0600 root root "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/podplane/etc/nat.env"
log "wrote /opt/podplane/etc/nat.env"
