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

# Baking and cloud-init both pass the target provider explicitly. AWS tests
# have no runtime configuration; local tests include conflicting runtime data
# to prove install.sh does not read it.
provider="${TEST_PROVIDER_KIND:-local}"
if [ "$provider" != aws ]; then
  rm -f "$ARTIFACTS_DIR/kube2iam.tar.gz"
  mkdir -p /opt/podplane/etc
  printf "PROVIDER_KIND='aws'\n" > /opt/podplane/etc/user-data.env
fi

if [ "$kind" = knd ] || [ "$kind" = knc ]; then
  for invalid_provider in '' awss; do
    log "checking rejection of missing or invalid install provider"
    if PROVIDER_KIND="$invalid_provider" "$INSTALL_SCRIPT" >/tmp/install-rejected.log 2>&1; then
      fatal "install succeeded without a valid explicit provider"
    fi
    grep -Fq 'PROVIDER_KIND must be one of:' /tmp/install-rejected.log || {
      cat /tmp/install-rejected.log
      fatal "install failed for a reason other than provider validation"
    }
    [ -f /opt/podplane/share/vmconfig-manifest.json ] || fatal "rejected install consumed manifest"
    [ ! -e /opt/podplane/share/vmconfig-installed.json ] || fatal "rejected install recorded completion"
    [ ! -e /opt/kube2iam/bin/kube2iam ] || fatal "rejected install extracted kube2iam"
    [ ! -e /usr/bin/kubelet ] || fatal "rejected install installed shared binaries"
    [ -d "$ARTIFACTS_DIR" ] || fatal "rejected install removed artifacts"
  done
fi

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
if [ "$kind" = knd ] || [ "$kind" = knc ]; then
  PROVIDER_KIND="$provider" "$INSTALL_SCRIPT"
else
  # Provider-neutral manifests still work without an explicit provider.
  env -u PROVIDER_KIND "$INSTALL_SCRIPT"
fi

if { [ "$kind" = knd ] || [ "$kind" = knc ]; } && [ "$provider" = aws ]; then
  [ -x /opt/kube2iam/bin/kube2iam ] || fatal "kube2iam binary was not installed on AWS"
  /opt/kube2iam/bin/kube2iam --help >/dev/null 2>&1 || fatal "kube2iam binary cannot run"
else
  [ ! -e /opt/kube2iam/bin/kube2iam ] || fatal "kube2iam binary installed outside AWS Kubernetes nodes"
fi

if [ "$kind" = knd ] || [ "$kind" = knc ] || [ "$kind" = nst ]; then
  log "checking registry installation"
  [ -x /usr/bin/registry ] || fatal "registry binary was not installed"
  [ -x /opt/registry/bin/run-registry.sh ] || fatal "registry launcher is missing"
  [ -f /etc/systemd/system/registry.service ] || fatal "registry systemd unit is missing"
fi
if [ "$kind" = knd ] || [ "$kind" = knc ]; then
  command -v bpftool >/dev/null 2>&1 || fatal "bpftool was not installed"
  log "checking gVisor installation"
  for path in /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin/gvisor_sentry; do
    [ -x "$path" ] || fatal "gVisor payload is incomplete: $path"
  done
  grep -Fq 'runtimes.runsc]' /etc/containerd/conf.d/gvisor.toml || fatal "runsc runtime handler is not configured"
  grep -Fxq 'binary_name = "/usr/local/bin/runsc"' /etc/containerd/runsc.toml || fatal "runsc shim configuration is missing"
fi
if [ "$kind" = nst ]; then
  log "checking gVisor absence"
  for path in /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin /etc/containerd/runsc.toml; do
    [ ! -e "$path" ] || fatal "nst install contains gVisor path: $path"
  done
  [ -z "$(ls -A /etc/containerd/conf.d 2>/dev/null)" ] || fatal "nst install contains containerd runtime drop-ins"
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
