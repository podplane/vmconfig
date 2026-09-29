#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Tests generated IPv4 NAT and NAT64 rules without changing host networking.

set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/templates/nat/opt/podplane/bin/nat-host.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/nat.env" <<'EOF'
NSTANCE_METRICS_INTERFACE=eth0
NAT_IPV4_SOURCE_CIDRS=10.0.0.0/8,192.168.0.0/16
NAT_CONNTRACK_MAX=524288
NAT64_ENABLED=true
NAT64_PREFIX=64:ff9b::/96
NAT64_SOURCE_IPV6_CIDRS=2001:db8:1::/64,2001:db8:2::/64
NAT64_POOL4_ADDRESS=192.0.2.10
EOF
NAT_ENV_FILE="$tmp/nat.env" bash "$SCRIPT" render >"$tmp/rules.nft"
grep -Fq 'oifname "eth0" masquerade' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.0.2.10 oifname "eth0" accept' "$tmp/rules.nft"
if grep -Fq 'iifname != "eth0"' "$tmp/rules.nft"; then
  echo 'same-interface forwarding is incorrectly blocked' >&2
  exit 1
fi
grep -Fq 'ip6 saddr != { 2001:db8:1::/64 , 2001:db8:2::/64 } drop' "$tmp/rules.nft"
grep -Fq '64:ff9b::a9fe:0/112' "$tmp/rules.nft"
grep -Fq '64:ff9b::c0a8:0/112' "$tmp/rules.nft"

sed -i.bak 's/NAT64_SOURCE_IPV6_CIDRS=.*/NAT64_SOURCE_IPV6_CIDRS=/' "$tmp/nat.env"
if NAT_ENV_FILE="$tmp/nat.env" bash "$SCRIPT" render >/dev/null 2>&1; then
  echo 'empty NAT64 source allowlist unexpectedly accepted' >&2
  exit 1
fi

echo 'nat-host tests passed'
