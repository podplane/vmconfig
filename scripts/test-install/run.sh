#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0
#
# run.sh - host-side orchestrator for the install.sh container test.
#
# 1. Detects the host architecture (so the container, the deps cache, and
#    the package tarball all agree on amd64 vs arm64).
# 2. Verifies the locally-built package tarball exists at
#    dist/vmconfig_<VER>_<KIND>_<OS>_<ARCH>.tar.gz (the Makefile target
#    that invokes this script depends on `package-<KIND>-<ARCH>`).
# 3. Populates temp/deps-cache/<KIND>/<OS>/<ARCH>/ via populate-cache.sh.
# 4. Builds the throw-away test image.
# 5. Runs install.sh inside the container with:
#      - the deps cache mounted read-only at /var/cache/vmconfig-deps
#      - the package tarball mounted read-only at /tmp/vmconfig-pkg.tar.gz
#
# Usage: run.sh <kind>

set -euo pipefail

KIND="${1:-}"
[ -n "$KIND" ] || { echo "usage: $0 <kind>" >&2; exit 1; }
case "$KIND" in
  knd|knc) ;;
  *) echo "kind must be knd or knc" >&2; exit 1 ;;
esac

OS_NAME="debian-13"
VERSION="${VERSION:-dev}"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_DIR="$REPO_ROOT/temp/deps-cache/${KIND}/${OS_NAME}/${ARCH}"
PKG_TARBALL="$REPO_ROOT/dist/vmconfig_${VERSION}_${KIND}_${OS_NAME}_${ARCH}.tar.gz"
IMAGE_TAG="vmconfig-test-install:${KIND}-${ARCH}"

command -v docker >/dev/null 2>&1 || {
  echo "FATAL: docker not found in PATH" >&2
  exit 1
}

[ -f "$PKG_TARBALL" ] || {
  echo "FATAL: missing $PKG_TARBALL" >&2
  echo "       run 'make package-${KIND}-${ARCH}' first" >&2
  exit 1
}

echo "[run] kind=$KIND arch=$ARCH version=$VERSION"
echo "[run] populating deps cache..."
"$SCRIPT_DIR/populate-cache.sh" "$KIND" "$ARCH"

echo "[run] building image $IMAGE_TAG..."
# --load is required when the active builder uses the docker-container driver
# (common with recent docker desktop / buildx defaults); otherwise the image
# stays in the build cache and `docker run` fails with "access denied".
docker build --load -t "$IMAGE_TAG" "$SCRIPT_DIR"

echo "[run] running install.sh in container..."
docker run --rm \
  -v "$CACHE_DIR:/var/cache/vmconfig-deps:ro" \
  -v "$PKG_TARBALL:/tmp/vmconfig-pkg.tar.gz:ro" \
  "$IMAGE_TAG"

echo "[run] test-install $KIND/$ARCH passed."
