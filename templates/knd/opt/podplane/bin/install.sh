#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0
#
# install.sh - installs the dependencies in /opt/podplane/deps/ after
# verifying them against the /opt/podplane/share/deps.json manifest.
#
# Idempotent and image-bake friendly: re-runs are no-ops upon first
# successful completion, where /opt/podplane/share/deps.json is
# renamed to deps-installed.json and /opt/podplane/deps is removed.
#
# This script does NOT require the /opt/podplane/user-data.env file
# used by the configure.sh script.
#
# Flow:
#   1. (preflight) checks
#   2. (install deps) if /opt/podplane/share/deps.json exists:
#        a. read kind from the manifest
#        b. sha256-verify every dep file against its digest (except vmconfig)
#        c. tar --diff the vmconfig tarball against / (catches partial
#           extraction; runs BEFORE permissions.sh so chmod/chown drift
#           can't false-positive)
#        d. install non-`vmconfig` deps in safe order:
#           i.)  debs first (uidmap provides getsubids needed by kubelet),
#           ii.) then tar.gz extracts, then plain binaries
#        e. mv deps.json -> deps-installed.json (in /opt/podplane/share/)
#   3. (cleanup) if /opt/podplane/deps exists: rm -rf /opt/podplane/deps
#   4. (permissions) invoke /opt/podplane/bin/permissions.sh "$kind"

set -euo pipefail

PODPLANE_DIR="/opt/podplane"
DEPS_DIR="${PODPLANE_DIR}/deps"
SHARE_DIR="${PODPLANE_DIR}/share"
DEPS_MANIFEST="${SHARE_DIR}/deps.json"
INSTALLED_MANIFEST="${SHARE_DIR}/deps-installed.json"
PERMISSIONS_SCRIPT="${PODPLANE_DIR}/bin/permissions.sh"

# functions ------------------------------------------------------------------

log()   { printf '[install] %s\n' "$*"; }
fatal() { printf '[install] FATAL: %s\n' "$*" >&2; exit 1; }
cleanup_deps_dir_if_exists() {
  if [ -d "$DEPS_DIR" ]; then
    log "removing ${DEPS_DIR}"
    rm -rf "$DEPS_DIR"
  fi
}

# 1. preflight ---------------------------------------------------------------

[ "$(id -u)" = "0" ] || fatal "must be run as root"

# Exit early if deps are already installed
if [ -f "$INSTALLED_MANIFEST" ]; then
  log "manifest at ${INSTALLED_MANIFEST} confirms deps installation is complete."
  cleanup_deps_dir_if_exists
  exit 0
fi

# Error if deps manifest does not exist
if [ ! -f "$DEPS_MANIFEST" ]; then
  fatal "required deps manifest at ${DEPS_MANIFEST} missing."
fi

# Check kind
KIND=$(jq -r '.vmconfig.kind' "$DEPS_MANIFEST")
case "$KIND" in
  knd|knc) ;;
  *) fatal "unsupported vmconfig.kind: '${KIND}'" ;;
esac

# Check deps dir
[ -d "$DEPS_DIR" ] || fatal "${DEPS_DIR} missing"

# Required tools used below
for tool in jq sha256sum tar dpkg install; do
  command -v "$tool" >/dev/null 2>&1 || fatal "required tool missing: ${tool}"
done

# 2. install -----------------------------------------------------------------

log "installing deps for instance kind=${KIND}"

# Verify every dep's sha256 up front, so we fail before any partial
# installation. Local filename is <key>.<ext>, with <ext> derived from
# .type (binary = no extension). `sha256sum -c` reads "<hex>  <path>".
log "verifying dep checksums..."
while IFS=$'\t' read -r name type digest; do
  # vmconfig is verified by tar --diff below, not by sha256.
  [ "$name" = "vmconfig" ] && continue
  case "$type" in
    binary) src="${DEPS_DIR}/${name}" ;;
    deb)    src="${DEPS_DIR}/${name}.deb" ;;
    tar.gz) src="${DEPS_DIR}/${name}.tar.gz" ;;
    *)      fatal "${name}: unsupported type '${type}'" ;;
  esac
  [ -n "$digest" ] || fatal "${name}: empty digest in manifest"
  echo "${digest#sha256:}  ${src}" | sha256sum -c --quiet \
    || fatal "${name}: sha256 verification failed"
done < <(jq -r '
  .vmconfig.dependencies | to_entries[]
  | "\(.key)\t\(.value.type)\t\(.value.digest)"
' "$DEPS_MANIFEST")

# tar --diff the vmconfig tarball (catches partial / truncated extracts).
# Must run BEFORE permissions.sh so mode/owner drift doesn't false-positive.
log "verifying vmconfig tarball extraction..."
tar --diff -zf "${DEPS_DIR}/vmconfig.tar.gz" -C / \
  || fatal "vmconfig.tar.gz contents do not match filesystem"

# Install order:
#   1. debs    - uidmap provides /usr/bin/getsubids that kubelet checks
#                at startup; libsubid5/libpq5 are runtime libs.
#   2. tar.gz  - containerd/crictl/registry to /usr/local/bin per
#                upstream docs; cni-plugins to /opt/cni/bin per CRI.
#   3. binary  - kubelet/kube-* to /usr/local/bin; runc to
#                /usr/local/sbin (FHS: system-level container runtime).
#
# policy-rc.d blocks dpkg postinst from starting services; configure.sh
# owns service lifecycle. The trap guarantees cleanup on failure.

# Populate the named array $1 with the keys of every dep of type $2.
# Usage: deps_of_type deb_names deb
deps_of_type() {
  # `out` is a bash nameref; shellcheck can't see that the caller observes
  # the mutation via the nameref, so suppress the spurious "appears unused"
  # warning on the mapfile line below.
  local -n out=$1
  # shellcheck disable=SC2034
  mapfile -t out < <(jq -r --arg t "$2" '
    .vmconfig.dependencies | to_entries[]
    | select(.value.type == $t)
    | .key
  ' "$DEPS_MANIFEST")
}

log "installing debs..."
deb_names=()
deps_of_type deb_names deb
# Batch into a single `dpkg -i` so dpkg resolves inter-deb deps for us
# (e.g. uidmap depends on libsubid5)
if [ "${#deb_names[@]}" -gt 0 ]; then
  debs=()
  for name in "${deb_names[@]}"; do
    debs+=("${DEPS_DIR}/${name}.deb")
  done
  # temporarily modify policy-rc.d to block dpkg postinst from starting services
  policy_rc="/usr/sbin/policy-rc.d"
  policy_rc_backup="${policy_rc}.podplane-bak"
  restore_policy_rc() {
    rm -f "$policy_rc"
    if [ -e "$policy_rc_backup" ]; then
      mv "$policy_rc_backup" "$policy_rc"
    fi
  }
  if [ -e "$policy_rc" ]; then
    mv "$policy_rc" "$policy_rc_backup"
  fi
  trap restore_policy_rc EXIT
  printf '#!/bin/sh\nexit 101\n' > "$policy_rc"
  chmod 0755 "$policy_rc"
  # install all debs via dpkg
  DEBIAN_FRONTEND=noninteractive dpkg -i "${debs[@]}"
  # restore original policy-rd.d
  restore_policy_rc
  trap - EXIT
fi

log "extracting tarballs..."
tarball_names=()
deps_of_type tarball_names tar.gz
for name in "${tarball_names[@]}"; do
  # vmconfig is already extracted to / by user-data; tar --diff above
  # has confirmed it. Skip here so we don't clobber it.
  [ "$name" = "vmconfig" ] && continue
  src="${DEPS_DIR}/${name}.tar.gz"
  case "$name" in
    containerd)  tar -xzf "$src" -C /usr/local bin/containerd bin/containerd-shim-runc-v2 bin/ctr ;;
    crictl)      tar -xzf "$src" -C /usr/local/bin crictl ;;
    registry)    tar -xzf "$src" -C /usr/local/bin registry ;;
    cni-plugins) mkdir -p /opt/cni/bin && tar -xzf "$src" -C /opt/cni/bin ;;
    *)           fatal "no extract rule for tarball ${name}" ;;
  esac
done

log "installing binaries..."
binary_names=()
deps_of_type binary_names binary
for name in "${binary_names[@]}"; do
  case "$name" in
    runc) dest=/usr/local/sbin ;;
    *)    dest=/usr/local/bin ;;
  esac
  install -m0755 -o root -g root "${DEPS_DIR}/${name}" "${dest}/${name}"
done

# Rename the deps.json manifest to deps-installed.json to prevent
# re-installation. The configure.sh script also depends on deps-installed.json.
# `touch` first so the audit mtime = install completion time.
touch "$DEPS_MANIFEST"
mv "$DEPS_MANIFEST" "$INSTALLED_MANIFEST"
log "recorded install in ${INSTALLED_MANIFEST}"

# 3. cleanup -----------------------------------------------------------------

cleanup_deps_dir_if_exists

# 4. enforce permissions -----------------------------------------------------

[ -x "$PERMISSIONS_SCRIPT" ] || fatal "missing or non-executable: ${PERMISSIONS_SCRIPT}"
"$PERMISSIONS_SCRIPT" "$KIND"

log "install.sh completed successfully."
