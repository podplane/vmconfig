#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Manages IPv4 NAT and optional NAT64 forwarding on a dedicated NAT instance.

set -euo pipefail

ENV_FILE="${NAT_ENV_FILE:-/opt/podplane/etc/nat.env}"
NFT_FILE="${NAT_NFT_FILE:-/run/podplane/nat.nft}"
JOOL_INSTANCE="podplane"

fatal() { printf '[nat-host] FATAL: %s\n' "$*" >&2; exit 1; }

[ -r "$ENV_FILE" ] || fatal "missing NAT environment file: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${NSTANCE_METRICS_INTERFACE:?NSTANCE_METRICS_INTERFACE is required}"
: "${NAT_IPV4_SOURCE_CIDRS:?NAT_IPV4_SOURCE_CIDRS is required}"
NAT_CONNTRACK_MAX="${NAT_CONNTRACK_MAX:-262144}"
NAT64_ENABLED="${NAT64_ENABLED:-false}"
NAT64_PREFIX="${NAT64_PREFIX:-64:ff9b::/96}"
NAT64_SOURCE_IPV6_CIDRS="${NAT64_SOURCE_IPV6_CIDRS:-}"
NAT64_BLOCKED_IPV6_CIDRS="${NAT64_BLOCKED_IPV6_CIDRS:-64:ff9b::/104,64:ff9b::a00:0/104,64:ff9b::6440:0/106,64:ff9b::7f00:0/104,64:ff9b::a9fe:0/112,64:ff9b::ac10:0/108,64:ff9b::c000:0/120,64:ff9b::c000:200/120,64:ff9b::c058:6300/120,64:ff9b::c0a8:0/112,64:ff9b::c612:0/111,64:ff9b::c633:6400/120,64:ff9b::cb00:7100/120,64:ff9b::e000:0/100,64:ff9b::f000:0/100}"
NAT64_POOL4_ADDRESS="${NAT64_POOL4_ADDRESS:-}"

case "$NSTANCE_METRICS_INTERFACE" in
  ''|*[!a-zA-Z0-9_.:-]*) fatal "invalid NSTANCE_METRICS_INTERFACE" ;;
esac
case "$NAT_CONNTRACK_MAX" in
  ''|*[!0-9]*) fatal "NAT_CONNTRACK_MAX must be a positive integer" ;;
  *) ((NAT_CONNTRACK_MAX > 0)) || fatal "NAT_CONNTRACK_MAX must be a positive integer" ;;
esac
case "$NAT64_ENABLED" in true|false) ;; *) fatal "NAT64_ENABLED must be true or false" ;; esac
if [ "$NAT64_ENABLED" = true ]; then
  case "$NAT64_PREFIX" in *:/96) ;; *) fatal "NAT64_PREFIX must be an IPv6 /96 prefix" ;; esac
  if [ "$NAT64_PREFIX" != 64:ff9b::/96 ] && [[ "$NAT64_BLOCKED_IPV6_CIDRS" == 64:ff9b::* ]]; then
    fatal "a non-default NAT64_PREFIX requires matching NAT64_BLOCKED_IPV6_CIDRS"
  fi
fi

# set_literal renders a validated comma-separated address list for nftables.
set_literal() {
  local values="$1"
  [ -n "$values" ] || fatal "$2 must not be empty"
  case "$values" in *[!0-9a-fA-F:.,/[:space:]]*) fatal "$2 contains invalid characters" ;; esac
  printf '{ %s }' "${values//,/ , }"
}

# set_sysctl writes and verifies one kernel setting.
set_sysctl() {
  local name="$1" value="$2" actual
  sysctl -q -w "$name=$value"
  actual=$(sysctl -n "$name")
  [ "$actual" = "$value" ] || fatal "$name is $actual after setting $value"
}

# render_rules writes the complete forwarding and translation ruleset.
render_rules() {
  local ipv4_sources ipv6_sources blocked
  ipv4_sources=$(set_literal "$NAT_IPV4_SOURCE_CIDRS" NAT_IPV4_SOURCE_CIDRS)
  cat <<EOF
table inet podplane_nat_filter {
  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ip saddr $ipv4_sources oifname "$NSTANCE_METRICS_INTERFACE" accept
EOF
  if [ "$NAT64_ENABLED" = true ]; then
    ipv6_sources=$(set_literal "$NAT64_SOURCE_IPV6_CIDRS" NAT64_SOURCE_IPV6_CIDRS)
    blocked=$(set_literal "$NAT64_BLOCKED_IPV6_CIDRS" NAT64_BLOCKED_IPV6_CIDRS)
    cat <<EOF
    ip6 saddr $ipv6_sources ip6 daddr $NAT64_PREFIX accept
    ip saddr $NAT64_POOL4_ADDRESS oifname "$NSTANCE_METRICS_INTERFACE" accept
EOF
  fi
  cat <<EOF
  }
}
table ip podplane_nat_snat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $ipv4_sources oifname "$NSTANCE_METRICS_INTERFACE" masquerade
  }
}
EOF
  if [ "$NAT64_ENABLED" = true ]; then
    cat <<EOF
table ip6 podplane_nat64_guard {
  chain prerouting {
    type filter hook prerouting priority -100; policy accept;
    ip6 daddr $NAT64_PREFIX ip6 saddr != $ipv6_sources drop
    ip6 daddr $blocked drop
  }
}
EOF
  fi
}

# check_jool_runtime verifies userspace and modules match the running kernel.
check_jool_runtime() {
  command -v jool >/dev/null || fatal "stateful Jool userspace runtime is not installed"
  command -v modinfo >/dev/null || fatal "modinfo is required"
  local module vermagic
  for module in jool_common jool; do
    modinfo "$module" >/dev/null 2>&1 || fatal "exact-kernel module $module is not installed"
    vermagic=$(modinfo -F vermagic "$module" | awk '{print $1}')
    [ "$vermagic" = "$(uname -r)" ] || fatal "$module vermagic $vermagic does not match $(uname -r)"
  done
}

# deactivate removes forwarding state and disables packet forwarding.
# it stops translation before removing its source/destination guard.
deactivate() {
  if command -v jool >/dev/null && jool -i "$JOOL_INSTANCE" global display >/dev/null 2>&1; then
    jool instance remove "$JOOL_INSTANCE"
  fi
  nft delete table ip6 podplane_nat64_guard 2>/dev/null || true
  nft delete table ip podplane_nat_snat 2>/dev/null || true
  nft delete table inet podplane_nat_filter 2>/dev/null || true
  set_sysctl net.ipv4.ip_forward 0
  set_sysctl net.ipv6.conf.all.forwarding 0
}

# activate replaces forwarding state after validating the complete configuration.
activate() {
  command -v nft >/dev/null || fatal "nft is required"
  ip link show dev "$NSTANCE_METRICS_INTERFACE" >/dev/null 2>&1 || fatal "metrics/egress interface does not exist: $NSTANCE_METRICS_INTERFACE"
  if [ "$NAT64_ENABLED" = true ]; then
    : "${NAT64_POOL4_ADDRESS:?NAT64_POOL4_ADDRESS is required when NAT64 is enabled}"
    case "$NAT64_POOL4_ADDRESS" in *[!0-9./]*) fatal "NAT64_POOL4_ADDRESS must be an IPv4 address or prefix" ;; esac
    check_jool_runtime
  fi
  install -d -m 0755 "$(dirname "$NFT_FILE")"
  render_rules >"$NFT_FILE.tmp"
  nft --check --file "$NFT_FILE.tmp"
  deactivate
  mv "$NFT_FILE.tmp" "$NFT_FILE"
  nft --file "$NFT_FILE"
  set_sysctl net.netfilter.nf_conntrack_max "$NAT_CONNTRACK_MAX"
  set_sysctl net.ipv4.ip_forward 1
  if [ "$NAT64_ENABLED" = true ]; then
    modprobe jool
    jool instance add "$JOOL_INSTANCE" --netfilter --pool6 "$NAT64_PREFIX"
    jool -i "$JOOL_INSTANCE" pool4 add --tcp "$NAT64_POOL4_ADDRESS" 61001-65535
    jool -i "$JOOL_INSTANCE" pool4 add --udp "$NAT64_POOL4_ADDRESS" 61001-65535
    jool -i "$JOOL_INSTANCE" pool4 add --icmp "$NAT64_POOL4_ADDRESS" 61001-65535
    set_sysctl net.ipv6.conf.all.forwarding 1
  fi
}

case "${1:-}" in
  activate) activate ;;
  deactivate) deactivate ;;
  render) render_rules ;;
  *) fatal "usage: $0 {activate|deactivate|render}" ;;
esac
