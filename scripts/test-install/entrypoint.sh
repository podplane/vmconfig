#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
#
# entrypoint.sh - container entrypoint for the install.sh test harness.
#
# Mirrors what cloud-init does on a real VM, then invokes install.sh:
#   1. Extract the vmconfig package tarball to /
#         (this populates /opt/podplane/{bin,share}/ etc.)
#   2. Stage cached artifacts into /opt/podplane/artifacts/
#         (the cache is mounted read-only at /var/cache/vmconfig-deps so the
#          rm -rf /opt/podplane/artifacts step in install.sh cannot delete it)
#   3. Stage the package tarball itself as /opt/podplane/artifacts/vmconfig.tar.gz
#         (install.sh runs `tar --diff` against this; it MUST be byte-identical
#          to whatever produced the on-disk tree, hence the same tarball used
#          in step 1 is reused here.)
#   4. Run install.sh, then run it again to verify the idempotent fast-path.

set -euo pipefail

PKG_TARBALL="/tmp/vmconfig-pkg.tar.gz"
DEPS_CACHE="/var/cache/vmconfig-deps"
ARTIFACTS_DIR="/opt/podplane/artifacts"
INSTALL_SCRIPT="/opt/podplane/bin/install.sh"

log() { printf '[entrypoint] %s\n' "$*"; }
fatal() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

[ -f "$PKG_TARBALL" ] || fatal "missing $PKG_TARBALL (mount the built package tarball here)"
[ -d "$DEPS_CACHE" ]  || fatal "missing $DEPS_CACHE (mount the populated deps cache here)"

log "extracting $PKG_TARBALL to /"
tar -xzf "$PKG_TARBALL" -C /
kind=$(sed -n -E 's/.*"kind"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' /opt/podplane/share/vmconfig-manifest.json | head -1)

log "staging artifacts from $DEPS_CACHE into $ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"
# Copy (don't link) so install.sh can rm -rf the directory without touching
# the host-mounted read-only cache.
cp -a "$DEPS_CACHE"/. "$ARTIFACTS_DIR"/
# vmconfig.tar.gz must be the same bytes as what we extracted in step 1
# so install.sh's `tar --diff` check passes.
cp -a "$PKG_TARBALL" "$ARTIFACTS_DIR/vmconfig.tar.gz"

# Docker shares the host kernel, while Jool modules intentionally target the
# Debian guest kernel. Override only uname -r so install.sh can verify the
# packaged module metadata in this container-only smoke test.
if [ "$kind" = nat ]; then
  kernel_release=$(tar -xOf "$DEPS_CACHE/jool-modules.tar.gz" metadata.json |
    sed -n -E 's/^[[:space:]]*"kernel_release":[[:space:]]*"([^"]+)",?$/\1/p')
  case "$kernel_release" in
    ''|*[!a-zA-Z0-9+._-]*) fatal "invalid Jool kernel release: $kernel_release" ;;
  esac
  mkdir -p /usr/local/lib/vmconfig-test
  cat > /usr/local/lib/vmconfig-test/uname <<EOF
#!/bin/sh
if [ "\${1:-}" = -r ]; then
  printf '%s\n' '$kernel_release'
else
  exec /usr/bin/uname "\$@"
fi
EOF
  chmod 0755 /usr/local/lib/vmconfig-test/uname
  export PATH="/usr/local/lib/vmconfig-test:$PATH"
fi

log "running install.sh (first invocation)"
"$INSTALL_SCRIPT"

if [ "$kind" = knd ] || [ "$kind" = knc ] || [ "$kind" = nst ]; then
  log "checking registry installation"
  [ -x /usr/bin/registry ] || fatal "registry binary was not installed"
  [ -x /opt/registry/bin/run-registry.sh ] || fatal "registry launcher is missing"
  [ -f /etc/systemd/system/registry.service ] || fatal "registry systemd unit is missing"
fi
if [ "$kind" = knd ] || [ "$kind" = knc ]; then
  command -v bpftool >/dev/null 2>&1 || fatal "bpftool was not installed"
fi
if [ "$kind" = knd ] || [ "$kind" = knc ] || [ "$kind" = nst ]; then
  [ "$(stat -c '%a:%U:%G' /etc/kubernetes/manifests)" = 700:root:root ] || fatal "invalid static Pod manifest directory permissions"
  grep -Fxq 'staticPodPath: /etc/kubernetes/manifests' /opt/kubelet/etc/kubelet.yaml || fatal "generic kubelet static Pod path is not configured"
fi
if [ "$kind" = knd ] || [ "$kind" = knc ]; then
  log "checking tunnel file storage"
  for path in /opt/podplane/tunnel /opt/podplane/tunnel/generations; do
    [ "$(stat -c '%a:%U:%G' "$path")" = 700:root:root ] || fatal "invalid tunnel path permissions: $path"
  done
fi
if [ "$kind" = nst ]; then
  [ "$(stat -c '%a:%U:%G' /run/nstance/tunnels)" = 700:root:root ] || fatal "invalid tunnel path permissions"
fi
if [ "$kind" = nat ]; then
  log "checking container runtime absence"
  if grep -Eq '"(containerd|kubelet|runc|crictl|cni-plugins)"[[:space:]]*:' /opt/podplane/share/vmconfig-installed.json ||
    grep -q '"images"[[:space:]]*:' /opt/podplane/share/vmconfig-installed.json; then
    fatal "NAT manifest contains container runtime artifacts"
  fi
  for path in COPYING NOTICE SOURCE; do
    [ -s "/usr/share/doc/podplane-jool/$path" ] || fatal "missing installed Jool documentation: $path"
  done
  for path in kernel-release architecture; do
    [ ! -e "/usr/share/doc/podplane-jool/$path" ] || fatal "unexpected Jool runtime metadata: $path"
  done
  for user in containerd kubelet; do
    ! id "$user" >/dev/null 2>&1 || fatal "NAT install created $user user"
  done
  for path in /usr/local/bin/containerd /usr/local/sbin/runc /usr/bin/kubelet /etc/containerd /opt/kubelet /etc/systemd/system/containerd.service /etc/systemd/system/kubelet.service /opt/podplane/lib/configure/containerd.sh; do
    [ ! -e "$path" ] || fatal "NAT install contains container runtime path: $path"
  done
fi

log "running install.sh (idempotency check; should hit early-exit)"
"$INSTALL_SCRIPT"

log "success"
