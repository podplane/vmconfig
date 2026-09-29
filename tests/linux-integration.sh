#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Tests eBPF connection counters and NAT forwarding in a privileged container.

set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE='docker.io/library/debian:13-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a'

if [ "${1:-}" != --inside ]; then
  exec docker run --rm --privileged --pid=host \
    --mount "type=bind,source=$ROOT,target=/workspace,readonly" \
    "$IMAGE" bash /workspace/tests/linux-integration.sh --inside
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq bpftool iproute2 iputils-ping jq mount netcat-openbsd nftables procps >/dev/null

loader=/workspace/templates/knd/opt/nstance-counters/bin/load.sh
nat=/workspace/templates/nat/opt/podplane/bin/nat-host.sh
export OBJECT=/workspace/templates/knd/opt/nstance-counters/lib/active-connections.bpf.o

# cleanup removes kernel state created by this test.
cleanup() {
  "$loader" --disable 2>/dev/null || true
  NAT_ENV_FILE=/tmp/nat.env "$nat" deactivate 2>/dev/null || true
  ip netns del vmconfig-client 2>/dev/null || true
  ip netns del vmconfig-internet 2>/dev/null || true
}
trap cleanup EXIT

# active_connections reads the first configured port from the pinned map.
active_connections() {
  local value
  value=$(bpftool -j map dump pinned /sys/fs/bpf/nstance/counters/maps/active_connections |
    jq -er '.[0].value | if type == "number" then tostring else .[0] end')
  case "$value" in
    0x*) printf '%d\n' "$((16#${value#0x}))" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

groupadd nstance-agent
useradd --system --gid nstance-agent nstance-agent
mkdir -p /sys/kernel/tracing
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
printf '443\n' >/tmp/production-ports
PORTS_FILE=/tmp/production-ports "$loader"

nc -l -p 443 >/dev/null &
server=$!
sleep 0.2
tail -f /dev/null | nc 127.0.0.1 443 &
client=$!
sleep 0.5
value=$(active_connections)
[ "$value" = 1 ] || { echo "active connection count is $value, want 1" >&2; exit 1; }
runuser -u nstance-agent -- test -r /sys/fs/bpf/nstance/counters/maps/active_connections
kill "$client"
wait "$client" 2>/dev/null || true
wait "$server" 2>/dev/null || true
sleep 0.5
value=$(active_connections)
[ "$value" = 0 ] || { echo "active connection count is $value, want 0" >&2; exit 1; }
"$loader" --disable

ip netns add vmconfig-client
ip netns add vmconfig-internet
ip link add nat-client type veth peer name client-nat
ip link set client-nat netns vmconfig-client
ip link add nat-out type veth peer name internet-nat
ip link set internet-nat netns vmconfig-internet
ip address add 10.0.0.1/24 dev nat-client
ip address add 192.0.2.1/24 dev nat-out
ip link set nat-client up
ip link set nat-out up
ip -n vmconfig-client address add 10.0.0.2/24 dev client-nat
ip -n vmconfig-client link set lo up
ip -n vmconfig-client link set client-nat up
ip -n vmconfig-client route add default via 10.0.0.1
ip -n vmconfig-internet address add 192.0.2.2/24 dev internet-nat
ip -n vmconfig-internet link set lo up
ip -n vmconfig-internet link set internet-nat up
conntrack_max=$(sysctl -n net.netfilter.nf_conntrack_max)
cat >/tmp/nat.env <<EOF
NSTANCE_METRICS_INTERFACE=nat-out
NAT_IPV4_SOURCE_CIDRS=10.0.0.0/24
NAT_CONNTRACK_MAX=$conntrack_max
NAT64_ENABLED=false
EOF
NAT_ENV_FILE=/tmp/nat.env "$nat" activate
ip netns exec vmconfig-client ping -c 1 -W 2 192.0.2.2 >/dev/null
NAT_ENV_FILE=/tmp/nat.env "$nat" deactivate
if ip netns exec vmconfig-client ping -c 1 -W 1 192.0.2.2 >/dev/null 2>&1; then
  echo 'forwarding remained active after NAT deactivation' >&2
  exit 1
fi

echo 'Linux integration tests passed'
