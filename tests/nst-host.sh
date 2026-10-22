#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Tests nst provisioning and shared service configuration without changing the host.

set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/temp"
tmp=$(mktemp -d "$root/temp/nst-host.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export PODPLANE_ROOT="$tmp/vm"
mkdir -p "$PODPLANE_ROOT" "$tmp/bin"
cp -R "$root/templates/common/." "$PODPLANE_ROOT/"
cp -R "$root/templates/container-runtime/." "$PODPLANE_ROOT/"
cp -R "$root/templates/nst/." "$PODPLANE_ROOT/"
mkdir -p "$PODPLANE_ROOT/opt/podplane/etc" "$PODPLANE_ROOT/opt/env"
cat > "$tmp/bin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

cat > "$PODPLANE_ROOT/opt/podplane/share/vmconfig-installed.json" <<'EOF'
{"vmconfig":{"kind":"nst","images":[{"image":"registry.k8s.io/pause:3.10"}]}}
EOF
cat > "$PODPLANE_ROOT/opt/podplane/etc/user-data.env" <<'EOF'
PROVIDER_KIND='local'
INSTANCE_PROVIDER_ID='aws:///us-east-1a/i-nst-test'
INSTANCE_NETDEV='eth0'
INSTANCE_IPV4='192.0.2.7'
INSTANCE_IPV6=''
INSTANCE_HOSTNAME='nst-test'
INSTANCE_FQDN='nst-test.example.com'
EOF
cat > "$PODPLANE_ROOT/opt/podplane/etc/mutable.env" <<'EOF'
NSTANCE_SERVER_SHARD='zone-a'
NSTANCE_SERVER_STORAGE='s3'
NSTANCE_SERVER_BUCKET='cluster-state'
NSTANCE_SLEEP_ENABLED='true'
NSTANCE_TUNNEL_ENABLED='true'
NSTANCE_TUNNEL_STORAGE='s3'
NSTANCE_TUNNEL_BUCKET='cluster-state'
NSTANCE_TUNNEL_SHARD='zone-a'
REGISTRY_BUCKET='cluster-images'
REGISTRY_HOSTNAME='registry.example.com'
TELEMETRY_LOG_CLOUDINIT='false'
EOF

bash "$PODPLANE_ROOT/opt/podplane/bin/bootstrap.sh"
for service in nstance-server registry containerd fluent-bit; do
  bash "$PODPLANE_ROOT/opt/podplane/lib/configure/$service.sh"
done
grep -Fxq "NSTANCE_SERVER_ID='i-nst-test'" "$PODPLANE_ROOT/opt/env/nstance-server.env"
grep -Fxq "NSTANCE_SERVER_BUCKET='cluster-state'" "$PODPLANE_ROOT/opt/env/nstance-server.env"
grep -Fxq "NSTANCE_SERVER_ADVERTISE_HOST='192.0.2.7'" "$PODPLANE_ROOT/opt/env/nstance-server.env"
grep -Fxq "REGISTRY_BUCKET='cluster-images'" "$PODPLANE_ROOT/opt/env/registry.env"
grep -Fq 'registry.example.com/mirror/registry.k8s.io/pause:3.10' "$PODPLANE_ROOT/etc/containerd/config.toml"
grep -Fxq 'TELEMETRY_LOG_CLOUDINIT=false' "$PODPLANE_ROOT/opt/env/fluent-bit.env"
grep -Fxq "TELEMETRY_ENABLED='true'" "$PODPLANE_ROOT/opt/env/fluent-bit.env"
cp "$PODPLANE_ROOT/opt/podplane/etc/mutable.env" "$tmp/before.env"
bash "$PODPLANE_ROOT/opt/podplane/bin/bootstrap.sh"
cmp "$tmp/before.env" "$PODPLANE_ROOT/opt/podplane/etc/mutable.env"

printf "INSTANCE_PROVIDER_ID='gce://example-project/us-central1-a/nst-example-0'\n" >> "$PODPLANE_ROOT/opt/podplane/etc/detected.env"
bash "$PODPLANE_ROOT/opt/podplane/lib/configure/nstance-server.sh"
grep -Fxq "NSTANCE_SERVER_ID='nst-example-0'" "$PODPLANE_ROOT/opt/env/nstance-server.env"

# Agent-managed nodes must still start from defaults rather than preserve overrides.
rm "$PODPLANE_ROOT/opt/podplane/bootstrap.done"
printf '{"vmconfig":{"kind":"knc"}}\n' > "$PODPLANE_ROOT/opt/podplane/share/vmconfig-installed.json"
bash "$PODPLANE_ROOT/opt/podplane/bin/bootstrap.sh"
cmp "$PODPLANE_ROOT/opt/podplane/share/defaults/mutable.env" "$PODPLANE_ROOT/opt/podplane/etc/mutable.env"
echo 'NST provisioning tests passed'
