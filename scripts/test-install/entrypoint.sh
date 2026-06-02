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

log "staging artifacts from $DEPS_CACHE into $ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"
# Copy (don't link) so install.sh can rm -rf the directory without touching
# the host-mounted read-only cache.
cp -a "$DEPS_CACHE"/. "$ARTIFACTS_DIR"/
# vmconfig.tar.gz must be the same bytes as what we extracted in step 1
# so install.sh's `tar --diff` check passes.
cp -a "$PKG_TARBALL" "$ARTIFACTS_DIR/vmconfig.tar.gz"

log "running install.sh (first invocation)"
"$INSTALL_SCRIPT"

log "running install.sh (idempotency check; should hit early-exit)"
"$INSTALL_SCRIPT"

log "success"
