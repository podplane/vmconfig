#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0
#
# populate-cache.sh - download (and sha256-verify) the dep artifacts
# referenced by deps/<kind>.<os>.<arch>.json into a persistent host cache
# under temp/deps-cache/<kind>/<os>/<arch>/, ready to be mounted into the
# install.sh test container.
#
# Idempotent: an already-cached file with a matching digest is left alone.
# A digest mismatch (e.g. after bumping a version in the manifest) triggers
# a re-download, so the cache is self-healing.
#
# The "vmconfig" entry is intentionally skipped here: it is supplied as the
# locally-built package tarball at run time, not downloaded.
#
# Usage: populate-cache.sh <kind> [<arch>]

set -euo pipefail

KIND="${1:-}"
ARCH="${2:-}"

[ -n "$KIND" ] || { echo "usage: $0 <kind> [<arch>]" >&2; exit 1; }
case "$KIND" in
  knd|knc) ;;
  *) echo "kind must be knd or knc" >&2; exit 1 ;;
esac

if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
  esac
fi

OS_NAME="debian-13"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/deps/${KIND}.${OS_NAME}.${ARCH}.json"
CACHE_DIR="$REPO_ROOT/temp/deps-cache/${KIND}/${OS_NAME}/${ARCH}"

[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 1; }

for tool in jq curl shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required tool missing: $tool" >&2
    exit 1
  }
done

mkdir -p "$CACHE_DIR"

log() { printf '[cache] %s\n' "$*"; }

# Returns 0 iff the file's sha256 matches the supplied "sha256:<hex>" digest.
verify() {
  local file="$1" digest="$2" actual
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  [ "$actual" = "${digest#sha256:}" ]
}

# Download to a sibling temp file, verify, then atomically rename into place.
# A failed download or mismatched digest is removed before returning non-zero.
download() {
  local url="$1" dest="$2" digest="$3" tmp
  tmp=$(mktemp "${dest}.XXXXXX")
  if ! curl -fsSL --retry 3 -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
  if ! verify "$tmp" "$digest"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
}

log "populating cache from $MANIFEST"
log "cache dir: $CACHE_DIR"

while IFS=$'\t' read -r name type digest url; do
  # vmconfig is staged from the locally-built package tarball at run time.
  [ "$name" = "vmconfig" ] && continue
  case "$type" in
    binary) ext="" ;;
    deb)    ext=".deb" ;;
    tar.gz) ext=".tar.gz" ;;
    *) echo "unsupported type '$type' for dep '$name'" >&2; exit 1 ;;
  esac
  dest="$CACHE_DIR/${name}${ext}"
  if [ -f "$dest" ] && verify "$dest" "$digest"; then
    log "$name: ok (cached)"
    continue
  fi
  log "$name: downloading $url"
  if ! download "$url" "$dest" "$digest"; then
    echo "[cache] FATAL: $name: download or digest verification failed" >&2
    exit 1
  fi
  log "$name: ok (downloaded)"
done < <(jq -r '
  .vmconfig.dependencies | to_entries[]
  | "\(.key)\t\(.value.type)\t\(.value.digest)\t\(.value.url)"
' "$MANIFEST")

log "done."
