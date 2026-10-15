#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Writes environment files for Nstance server, proxy, and tunnel services.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../helpers.sh"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/detected.env"

for name in NSTANCE_SERVER_ID NSTANCE_SERVER_SHARD NSTANCE_SERVER_STORAGE NSTANCE_SERVER_BUCKET NSTANCE_SERVER_ADVERTISE_HOST; do
  require_nonempty "$name"
done
for name in NSTANCE_SLEEP_ENABLED NSTANCE_TUNNEL_ENABLED; do
  case "${!name:-}" in
    true|false) ;;
    *) fatal "$name must be explicitly set to true or false" ;;
  esac
done

mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/nstance-server.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
NSTANCE_SERVER_ID=$(quote_env_value "$NSTANCE_SERVER_ID")
NSTANCE_SERVER_SHARD=$(quote_env_value "$NSTANCE_SERVER_SHARD")
NSTANCE_SERVER_STORAGE=$(quote_env_value "$NSTANCE_SERVER_STORAGE")
NSTANCE_SERVER_BUCKET=$(quote_env_value "$NSTANCE_SERVER_BUCKET")
NSTANCE_SERVER_PREFIX=$(quote_env_value "${NSTANCE_SERVER_PREFIX:-}")
NSTANCE_SERVER_CACHE_DIR='/opt/nstance-server/cache'
NSTANCE_SERVER_ADVERTISE_HOST=$(quote_env_value "$NSTANCE_SERVER_ADVERTISE_HOST")
NSTANCE_SERVER_PROXY_SOCKET='/run/nstance/proxy/nstance-server.sock'
NSTANCE_SERVER_TUNNEL_SOCKET='/run/nstance/tunnel/nstance-tunnel.sock'
NSTANCE_SERVER_FILES_DIR='/run/nstance/files'
EOF
set_file_permissions 0640 root nstance-server "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/nstance-server.env"

tmp="/opt/env/nstance-server-proxy.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
NSTANCE_PROXY_SOCKET='/run/nstance/proxy/nstance-server.sock'
NSTANCE_PROXY_BIND_HOST=$(quote_env_value "${NSTANCE_PROXY_BIND_HOST:-}")
EOF
set_file_permissions 0640 root nstance-proxy "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/nstance-server-proxy.env"

if [ "$NSTANCE_TUNNEL_ENABLED" = true ]; then
  for name in NSTANCE_TUNNEL_STORAGE NSTANCE_TUNNEL_BUCKET NSTANCE_TUNNEL_SHARD; do
    require_nonempty "$name"
  done
fi
tmp="/opt/env/nstance-server-tunnel.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
NSTANCE_TUNNEL_STORAGE=$(quote_env_value "${NSTANCE_TUNNEL_STORAGE:-}")
NSTANCE_TUNNEL_BUCKET=$(quote_env_value "${NSTANCE_TUNNEL_BUCKET:-}")
NSTANCE_TUNNEL_SHARD=$(quote_env_value "${NSTANCE_TUNNEL_SHARD:-}")
NSTANCE_TUNNEL_PREFIX=$(quote_env_value "${NSTANCE_TUNNEL_PREFIX:-}")
NSTANCE_TUNNEL_SOCKET='/run/nstance/tunnel/nstance-tunnel.sock'
NSTANCE_TUNNEL_MANIFEST_DIR='/etc/kubernetes/manifests'
NSTANCE_TUNNEL_FILES_DIR='/run/nstance/tunnels'
EOF
set_file_permissions 0600 root root "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/nstance-server-tunnel.env"
log "wrote nstance-server environment files"
